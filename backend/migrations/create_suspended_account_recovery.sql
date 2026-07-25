-- Single-purpose recovery tokens for suspended users to appeal without product access.
BEGIN;
CREATE TABLE suspended_account_recovery_tokens (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
 suspension_id UUID NOT NULL REFERENCES user_account_suspensions(id) ON DELETE RESTRICT,
 case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
 token_digest CHAR(64) NOT NULL UNIQUE CHECK(token_digest ~ '^[0-9a-f]{64}$'),
 delivery_channel TEXT NOT NULL CHECK(delivery_channel IN ('email','sms')),
 requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), expires_at TIMESTAMPTZ NOT NULL,
 consumed_at TIMESTAMPTZ, invalidated_at TIMESTAMPTZ, invalidation_reason_code TEXT,
 CHECK(expires_at>requested_at), CHECK(NOT(consumed_at IS NOT NULL AND invalidated_at IS NOT NULL)),
 CHECK((invalidated_at IS NULL AND invalidation_reason_code IS NULL) OR
       (invalidated_at IS NOT NULL AND invalidation_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$')));
CREATE INDEX idx_suspended_recovery_user ON suspended_account_recovery_tokens(user_id,requested_at DESC);
CREATE TABLE suspended_account_recovery_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), token_id UUID NOT NULL REFERENCES suspended_account_recovery_tokens(id) ON DELETE RESTRICT,
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT, case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
 event_type TEXT NOT NULL CHECK(event_type IN ('issued','inspected','consumed','invalidated')),
 reason_code TEXT, occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CHECK(reason_code IS NULL OR reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'));
CREATE TABLE user_account_suspension_trust_links (
 suspension_id UUID PRIMARY KEY REFERENCES user_account_suspensions(id) ON DELETE RESTRICT,
 case_id UUID NOT NULL UNIQUE REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
 decision_id UUID NOT NULL UNIQUE REFERENCES trust_review_decisions(id) ON DELETE RESTRICT,
 linked_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT, linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
CREATE OR REPLACE FUNCTION protect_suspended_recovery_token() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_OP='UPDATE' AND (to_jsonb(OLD)-'consumed_at'-'invalidated_at'-'invalidation_reason_code')=(to_jsonb(NEW)-'consumed_at'-'invalidated_at'-'invalidation_reason_code')
  AND OLD.consumed_at IS NULL AND OLD.invalidated_at IS NULL AND ((NEW.consumed_at IS NOT NULL AND NEW.invalidated_at IS NULL) OR (NEW.invalidated_at IS NOT NULL AND NEW.consumed_at IS NULL)) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'Suspended-account recovery token history is immutable'; END; $$;
CREATE OR REPLACE FUNCTION protect_suspended_recovery_event() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN RAISE EXCEPTION 'Suspended-account recovery event history is immutable'; END; $$;
CREATE TRIGGER suspended_recovery_token_history BEFORE UPDATE OR DELETE ON suspended_account_recovery_tokens FOR EACH ROW EXECUTE FUNCTION protect_suspended_recovery_token();
CREATE TRIGGER suspended_recovery_events_append_only BEFORE UPDATE OR DELETE ON suspended_account_recovery_events FOR EACH ROW EXECUTE FUNCTION protect_suspended_recovery_event();
CREATE TRIGGER user_suspension_trust_links_immutable BEFORE UPDATE OR DELETE ON user_account_suspension_trust_links FOR EACH ROW EXECUTE FUNCTION protect_suspended_recovery_event();
CREATE OR REPLACE FUNCTION suspend_trust_user(p_actor UUID,p_user UUID,p_case UUID,p_reason_code TEXT,p_reason_note TEXT,p_idempotency_key TEXT,p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d trust_review_decisions; s user_account_suspensions; result JSONB;
BEGIN
 PERFORM trust_require_platform_admin(p_actor);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT||':user.suspend:'||p_idempotency_key,0));
 result:=trust_existing_result(p_actor,'user.suspend',p_idempotency_key,p_request_hash); IF result IS NOT NULL THEN RETURN result; END IF;
 SELECT decision.* INTO d FROM trust_review_decisions decision JOIN trust_review_cases c ON c.id=decision.case_id WHERE c.id=p_case AND c.subject_type='user' AND c.subject_id=p_user AND c.status='decided' AND decision.outcome='suspend_user';
 IF d.id IS NULL THEN RAISE EXCEPTION 'Eligible user suspension decision not found'; END IF;
 result:=suspend_platform_user(p_actor,p_user,p_reason_code,p_reason_note);
 SELECT * INTO s FROM user_account_suspensions WHERE user_id=p_user AND status='active';
 INSERT INTO user_account_suspension_trust_links(suspension_id,case_id,decision_id,linked_by) VALUES(s.id,p_case,d.id,p_actor)
 ON CONFLICT(suspension_id) DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM user_account_suspension_trust_links WHERE suspension_id=s.id AND case_id=p_case AND decision_id=d.id) THEN RAISE EXCEPTION 'Active suspension is linked to another decision'; END IF;
 result:=result||jsonb_build_object('caseId',p_case,'decisionId',d.id);
 RETURN trust_store_result(p_actor,'user.suspend',p_idempotency_key,p_request_hash,result); END; $$;
CREATE OR REPLACE FUNCTION issue_suspended_account_recovery(p_user UUID,p_case UUID,p_token_digest TEXT,p_channel TEXT,p_expires_at TIMESTAMPTZ)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE s user_account_suspensions; t suspended_account_recovery_tokens;
BEGIN
 IF p_token_digest !~ '^[0-9a-f]{64}$' OR p_channel NOT IN ('email','sms') OR p_expires_at<NOW()+INTERVAL '5 minutes' OR p_expires_at>NOW()+INTERVAL '30 minutes' THEN RAISE EXCEPTION 'Invalid recovery request'; END IF;
 SELECT * INTO s FROM user_account_suspensions WHERE user_id=p_user AND status='active' FOR UPDATE;
 IF s.id IS NULL OR NOT EXISTS(SELECT 1 FROM user_account_suspension_trust_links l JOIN trust_review_cases c ON c.id=l.case_id JOIN trust_review_decisions d ON d.id=l.decision_id WHERE l.suspension_id=s.id AND c.id=p_case AND c.subject_type='user' AND c.subject_id=p_user AND c.status='decided' AND d.outcome='suspend_user') THEN RAISE EXCEPTION 'Eligible suspended account decision not found'; END IF;
 WITH prior AS (UPDATE suspended_account_recovery_tokens SET invalidated_at=NOW(),invalidation_reason_code='SUPERSEDED' WHERE user_id=p_user AND consumed_at IS NULL AND invalidated_at IS NULL RETURNING *) INSERT INTO suspended_account_recovery_events(token_id,user_id,case_id,event_type,reason_code) SELECT id,user_id,case_id,'invalidated','SUPERSEDED' FROM prior;
 INSERT INTO suspended_account_recovery_tokens(user_id,suspension_id,case_id,token_digest,delivery_channel,expires_at) VALUES(p_user,s.id,p_case,p_token_digest,p_channel,p_expires_at) RETURNING * INTO t;
 INSERT INTO suspended_account_recovery_events(token_id,user_id,case_id,event_type) VALUES(t.id,p_user,p_case,'issued');
 RETURN jsonb_build_object('tokenId',t.id,'userId',p_user,'caseId',p_case,'channel',p_channel,'expiresAt',t.expires_at); END; $$;
CREATE OR REPLACE FUNCTION inspect_suspended_account_recovery(p_token_digest TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t suspended_account_recovery_tokens; a trust_appeals;
BEGIN
 SELECT * INTO t FROM suspended_account_recovery_tokens WHERE token_digest=p_token_digest;
 IF t.id IS NULL OR t.consumed_at IS NOT NULL OR t.invalidated_at IS NOT NULL OR t.expires_at<=NOW() OR NOT EXISTS(SELECT 1 FROM users WHERE id=t.user_id AND is_suspended=TRUE) THEN RAISE EXCEPTION 'Invalid or expired recovery token'; END IF;
 SELECT * INTO a FROM trust_appeals WHERE case_id=t.case_id AND appellant_id=t.user_id ORDER BY filed_at DESC LIMIT 1;
 INSERT INTO suspended_account_recovery_events(token_id,user_id,case_id,event_type) VALUES(t.id,t.user_id,t.case_id,'inspected');
 RETURN jsonb_build_object('caseId',t.case_id,'suspended',TRUE,'expiresAt',t.expires_at,'appealStatus',a.status); END; $$;
CREATE OR REPLACE FUNCTION file_suspended_account_recovery_appeal(p_token_digest TEXT,p_grounds TEXT,p_idempotency_key TEXT,p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t suspended_account_recovery_tokens; r JSONB;
BEGIN
 SELECT * INTO t FROM suspended_account_recovery_tokens WHERE token_digest=p_token_digest FOR UPDATE;
 IF t.id IS NULL THEN RAISE EXCEPTION 'Invalid or expired recovery token'; END IF;
 IF t.consumed_at IS NOT NULL THEN r:=trust_existing_result(t.user_id,'appeal.file',p_idempotency_key,p_request_hash); IF r IS NOT NULL THEN RETURN r; END IF; RAISE EXCEPTION 'Invalid or expired recovery token'; END IF;
 IF t.invalidated_at IS NOT NULL OR t.expires_at<=NOW() OR NOT EXISTS(SELECT 1 FROM users WHERE id=t.user_id AND is_suspended=TRUE) THEN RAISE EXCEPTION 'Invalid or expired recovery token'; END IF;
 r:=file_trust_appeal(t.user_id,t.case_id,p_grounds,p_idempotency_key,p_request_hash);
 UPDATE suspended_account_recovery_tokens SET consumed_at=NOW() WHERE id=t.id;
 INSERT INTO suspended_account_recovery_events(token_id,user_id,case_id,event_type) VALUES(t.id,t.user_id,t.case_id,'consumed'); RETURN r; END; $$;
CREATE OR REPLACE FUNCTION invalidate_suspended_account_recovery(p_token UUID,p_reason_code TEXT) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t suspended_account_recovery_tokens; BEGIN
 IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN RAISE EXCEPTION 'Invalid reason code'; END IF;
 UPDATE suspended_account_recovery_tokens SET invalidated_at=NOW(),invalidation_reason_code=p_reason_code WHERE id=p_token AND consumed_at IS NULL AND invalidated_at IS NULL RETURNING * INTO t;
 IF t.id IS NOT NULL THEN INSERT INTO suspended_account_recovery_events(token_id,user_id,case_id,event_type,reason_code) VALUES(t.id,t.user_id,t.case_id,'invalidated',p_reason_code); END IF; END; $$;
ALTER TABLE suspended_account_recovery_tokens ENABLE ROW LEVEL SECURITY; ALTER TABLE suspended_account_recovery_events ENABLE ROW LEVEL SECURITY; ALTER TABLE user_account_suspension_trust_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON suspended_account_recovery_tokens,suspended_account_recovery_events,user_account_suspension_trust_links FROM anon,authenticated;
REVOKE ALL ON FUNCTION suspend_trust_user(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT),issue_suspended_account_recovery(UUID,UUID,TEXT,TEXT,TIMESTAMPTZ),inspect_suspended_account_recovery(TEXT),file_suspended_account_recovery_appeal(TEXT,TEXT,TEXT,TEXT),invalidate_suspended_account_recovery(UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION suspend_trust_user(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT),issue_suspended_account_recovery(UUID,UUID,TEXT,TEXT,TIMESTAMPTZ),inspect_suspended_account_recovery(TEXT),file_suspended_account_recovery_appeal(TEXT,TEXT,TEXT,TEXT),invalidate_suspended_account_recovery(UUID,TEXT) TO service_role;
COMMIT;