-- Idempotent, immutable legal-hold placement and release commands.
BEGIN;
ALTER TABLE data_legal_holds ADD COLUMN placement_note TEXT CHECK(placement_note IS NULL OR char_length(placement_note)<=1000);
ALTER TABLE data_legal_holds ADD COLUMN release_note TEXT CHECK(release_note IS NULL OR char_length(release_note)<=1000);
CREATE UNIQUE INDEX uq_active_data_legal_hold ON data_legal_holds(organization_id,subject_type,subject_id) NULLS NOT DISTINCT WHERE status='active';
CREATE TABLE data_legal_hold_events(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), hold_id UUID NOT NULL REFERENCES data_legal_holds(id) ON DELETE RESTRICT,
 organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT, actor_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
 event_type TEXT NOT NULL CHECK(event_type IN('placed','released')), reason_code TEXT NOT NULL CHECK(reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
 occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
CREATE INDEX idx_data_legal_hold_events ON data_legal_hold_events(hold_id,occurred_at);
CREATE OR REPLACE FUNCTION protect_data_legal_hold() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='active' AND NEW.status='released'
  AND (to_jsonb(OLD)-'status'-'released_by'-'released_at'-'release_reason_code'-'release_note')=(to_jsonb(NEW)-'status'-'released_by'-'released_at'-'release_reason_code'-'release_note')
  AND NEW.released_by IS NOT NULL AND NEW.released_at IS NOT NULL AND NEW.release_reason_code IS NOT NULL THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'Legal hold history is immutable'; END; $$;
CREATE TRIGGER data_legal_holds_history BEFORE UPDATE OR DELETE ON data_legal_holds FOR EACH ROW EXECUTE FUNCTION protect_data_legal_hold();
CREATE TRIGGER data_legal_hold_events_append_only BEFORE UPDATE OR DELETE ON data_legal_hold_events FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE OR REPLACE FUNCTION validate_legal_hold_subject(p_organization UUID,p_type TEXT,p_subject TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF p_type NOT IN('user','organization','membership','case','data_class') OR char_length(trim(p_subject)) NOT BETWEEN 1 AND 256 THEN RAISE EXCEPTION 'Invalid legal hold subject'; END IF;
 IF p_type<>'data_class' AND p_subject !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'Invalid legal hold subject'; END IF;
 IF p_type='organization' AND (p_organization IS NULL OR p_subject::UUID<>p_organization OR NOT EXISTS(SELECT 1 FROM organizations WHERE id=p_organization)) THEN RAISE EXCEPTION 'Legal hold subject is outside organization scope';
 ELSIF p_type='membership' AND (p_organization IS NULL OR NOT EXISTS(SELECT 1 FROM organization_memberships WHERE id=p_subject::UUID AND organization_id=p_organization)) THEN RAISE EXCEPTION 'Legal hold subject is outside organization scope';
 ELSIF p_type='case' AND NOT EXISTS(SELECT 1 FROM trust_review_cases WHERE id=p_subject::UUID AND organization_id IS NOT DISTINCT FROM p_organization) THEN RAISE EXCEPTION 'Legal hold subject is outside organization scope';
 ELSIF p_type='user' AND (NOT EXISTS(SELECT 1 FROM users WHERE id=p_subject::UUID) OR (p_organization IS NOT NULL AND NOT EXISTS(SELECT 1 FROM organization_memberships WHERE user_id=p_subject::UUID AND organization_id=p_organization))) THEN RAISE EXCEPTION 'Legal hold subject is outside organization scope';
 ELSIF p_type='data_class' AND (p_subject !~ '^[a-z][a-z0-9_.]{2,63}$' OR NOT EXISTS(SELECT 1 FROM data_retention_policies WHERE data_class=p_subject AND organization_id IS NOT DISTINCT FROM p_organization)) THEN RAISE EXCEPTION 'Legal hold data class is outside policy scope'; END IF;
END; $$;
CREATE OR REPLACE FUNCTION place_data_legal_hold(p_actor UUID,p_organization UUID,p_type TEXT,p_subject TEXT,p_reason_code TEXT,p_note TEXT,p_idempotency_key TEXT,p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE h data_legal_holds; result JSONB;
BEGIN
 PERFORM trust_require_platform_admin(p_actor); PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT||':legal-hold.place:'||p_idempotency_key,0));
 result:=trust_existing_result(p_actor,'legal_hold.place',p_idempotency_key,p_request_hash); IF result IS NOT NULL THEN RETURN result; END IF;
 IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR (p_note IS NOT NULL AND char_length(trim(p_note))>1000) THEN RAISE EXCEPTION 'Invalid legal hold reason'; END IF;
 PERFORM validate_legal_hold_subject(p_organization,p_type,trim(p_subject));
 SELECT * INTO h FROM data_legal_holds WHERE organization_id IS NOT DISTINCT FROM p_organization AND subject_type=p_type AND subject_id=trim(p_subject) AND status='active' FOR UPDATE;
 IF h.id IS NULL THEN INSERT INTO data_legal_holds(organization_id,subject_type,subject_id,reason_code,placement_note,placed_by) VALUES(p_organization,p_type,trim(p_subject),p_reason_code,NULLIF(trim(p_note),''),p_actor) RETURNING * INTO h;
  INSERT INTO data_legal_hold_events(hold_id,organization_id,actor_id,event_type,reason_code) VALUES(h.id,p_organization,p_actor,'placed',p_reason_code); END IF;
 result:=jsonb_build_object('holdId',h.id,'organizationId',h.organization_id,'subjectType',h.subject_type,'subjectId',h.subject_id,'status',h.status,'placedAt',h.placed_at);
 RETURN trust_store_result(p_actor,'legal_hold.place',p_idempotency_key,p_request_hash,result); END; $$;
CREATE OR REPLACE FUNCTION release_data_legal_hold(p_actor UUID,p_hold UUID,p_reason_code TEXT,p_note TEXT,p_idempotency_key TEXT,p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE h data_legal_holds; result JSONB;
BEGIN
 PERFORM trust_require_platform_admin(p_actor); PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT||':legal-hold.release:'||p_idempotency_key,0));
 result:=trust_existing_result(p_actor,'legal_hold.release',p_idempotency_key,p_request_hash); IF result IS NOT NULL THEN RETURN result; END IF;
 IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR (p_note IS NOT NULL AND char_length(trim(p_note))>1000) THEN RAISE EXCEPTION 'Invalid legal hold release reason'; END IF;
 SELECT * INTO h FROM data_legal_holds WHERE id=p_hold FOR UPDATE; IF h.id IS NULL THEN RAISE EXCEPTION 'Legal hold not found'; END IF;
 IF h.status='active' THEN UPDATE data_legal_holds SET status='released',released_by=p_actor,released_at=NOW(),release_reason_code=p_reason_code,release_note=NULLIF(trim(p_note),'') WHERE id=p_hold RETURNING * INTO h;
  INSERT INTO data_legal_hold_events(hold_id,organization_id,actor_id,event_type,reason_code) VALUES(h.id,h.organization_id,p_actor,'released',p_reason_code); END IF;
 result:=jsonb_build_object('holdId',h.id,'organizationId',h.organization_id,'subjectType',h.subject_type,'subjectId',h.subject_id,'status',h.status,'releasedAt',h.released_at);
 RETURN trust_store_result(p_actor,'legal_hold.release',p_idempotency_key,p_request_hash,result); END; $$;
INSERT INTO feature_flags(key,domain,description,default_enabled,failure_mode,risk) VALUES('trust.legal_holds','trust','Place new legal holds; existing holds can always be released.',FALSE,'closed','regulated') ON CONFLICT(key) DO UPDATE SET domain=EXCLUDED.domain,description=EXCLUDED.description,default_enabled=EXCLUDED.default_enabled,failure_mode=EXCLUDED.failure_mode,risk=EXCLUDED.risk,updated_at=NOW();
ALTER TABLE data_legal_hold_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON data_legal_hold_events FROM anon,authenticated;
REVOKE ALL ON FUNCTION validate_legal_hold_subject(UUID,TEXT,TEXT),place_data_legal_hold(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),release_data_legal_hold(UUID,UUID,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION place_data_legal_hold(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),release_data_legal_hold(UUID,UUID,TEXT,TEXT,TEXT,TEXT) TO service_role;
COMMIT;