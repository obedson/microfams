-- GT-02B2: versioned entry rules, proposal-backed admission, and verified fee activation.
SET search_path=public,extensions;

CREATE TABLE IF NOT EXISTS group_entry_requirement_versions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
 version INTEGER NOT NULL CHECK(version>0),state TEXT NOT NULL CHECK(state IN('effective','superseded')),
 entry_fee_amount_minor BIGINT NOT NULL CHECK(entry_fee_amount_minor>=0),currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
 required_identity_tier TEXT NOT NULL CHECK(required_identity_tier IN('none','nin_verified')),
 eligibility_rules JSONB NOT NULL DEFAULT '{}'::JSONB CHECK(jsonb_typeof(eligibility_rules)='object'),
 approval_route TEXT NOT NULL DEFAULT 'proposal' CHECK(approval_route='proposal'),capacity_limit INTEGER NOT NULL CHECK(capacity_limit>0),effective_from TIMESTAMPTZ NOT NULL,
 superseded_at TIMESTAMPTZ,created_by UUID NOT NULL REFERENCES users(id),created_at TIMESTAMPTZ NOT NULL,
 UNIQUE(group_id,version),CHECK((state='superseded')=(superseded_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_effective_entry_requirement ON group_entry_requirement_versions(group_id) WHERE state='effective';
CREATE INDEX IF NOT EXISTS idx_group_entry_requirement_tenant ON group_entry_requirement_versions(organization_id,group_id,state);

CREATE TABLE IF NOT EXISTS group_entry_requirement_events(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
 requirement_version_id UUID NOT NULL REFERENCES group_entry_requirement_versions(id) ON DELETE RESTRICT,actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
 event_type TEXT NOT NULL CHECK(event_type~'^[A-Z][A-Z0-9_]{2,63}$'),correlation_id UUID NOT NULL,
 evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK(jsonb_typeof(evidence)='object'),occurred_at TIMESTAMPTZ NOT NULL,
 UNIQUE(organization_id,correlation_id)
);

ALTER TABLE group_membership_invitations ADD COLUMN IF NOT EXISTS entry_requirement_version_id UUID REFERENCES group_entry_requirement_versions(id) ON DELETE RESTRICT;
ALTER TABLE group_members ADD COLUMN IF NOT EXISTS entry_requirement_version_id UUID REFERENCES group_entry_requirement_versions(id) ON DELETE RESTRICT,
 ADD COLUMN IF NOT EXISTS admission_proposal_id UUID REFERENCES group_proposals(id) ON DELETE RESTRICT,
 ADD COLUMN IF NOT EXISTS admission_decided_at TIMESTAMPTZ;

INSERT INTO group_entry_requirement_versions(organization_id,group_id,constitution_id,version,state,entry_fee_amount_minor,currency,required_identity_tier,eligibility_rules,capacity_limit,effective_from,created_by,created_at)
SELECT g.organization_id,g.id,g.current_constitution_id,1,'effective',ROUND(COALESCE(g.entry_fee,0)*100)::BIGINT,'NGN','nin_verified','{}',g.max_members,COALESCE(g.activated_at,g.created_at),g.creator_id,COALESCE(g.activated_at,g.created_at)
FROM groups g WHERE g.current_constitution_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM group_entry_requirement_versions r WHERE r.group_id=g.id);
UPDATE group_membership_invitations i SET entry_requirement_version_id=r.id FROM group_entry_requirement_versions r
 WHERE r.group_id=i.group_id AND r.state='effective' AND i.entry_requirement_version_id IS NULL;
UPDATE group_members m SET entry_requirement_version_id=i.entry_requirement_version_id FROM group_membership_invitations i
 WHERE i.group_id=m.group_id AND i.intended_user_id=m.user_id AND i.state='accepted' AND m.entry_requirement_version_id IS NULL;
ALTER TABLE group_membership_invitations ALTER COLUMN entry_requirement_version_id SET NOT NULL;

CREATE TABLE IF NOT EXISTS group_membership_payment_allocations(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
 membership_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,entry_requirement_version_id UUID NOT NULL REFERENCES group_entry_requirement_versions(id) ON DELETE RESTRICT,
 payment_id UUID NOT NULL UNIQUE REFERENCES payments(id) ON DELETE RESTRICT,amount_minor BIGINT NOT NULL CHECK(amount_minor>0),currency VARCHAR(3) NOT NULL,
 state TEXT NOT NULL DEFAULT 'allocated' CHECK(state IN('allocated','reversed')),allocation_journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
 reversal_id UUID UNIQUE REFERENCES payment_reversals(id),reversal_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),allocated_at TIMESTAMPTZ NOT NULL,reversed_at TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION protect_group_entry_evidence() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.group_membership_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;END IF;RAISE EXCEPTION 'GROUP_MEMBERSHIP_ENGINE_REQUIRED';END $$;
DO $$DECLARE t TEXT;BEGIN FOREACH t IN ARRAY ARRAY['group_entry_requirement_versions','group_entry_requirement_events','group_membership_payment_allocations'] LOOP EXECUTE format('DROP TRIGGER IF EXISTS protect_group_entry_evidence ON %I',t);EXECUTE format('CREATE TRIGGER protect_group_entry_evidence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION protect_group_entry_evidence()',t);END LOOP;END $$;

CREATE OR REPLACE FUNCTION protect_group_membership_state() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF (NEW.status,NEW.state_version,NEW.status_reason_code,NEW.exiting_at,NEW.exited_at,NEW.expelled_at,NEW.is_active,NEW.payment_status,NEW.payment_reference,NEW.amount_paid,NEW.paid_at,NEW.entry_requirement_version_id,NEW.admission_proposal_id,NEW.admission_decided_at) IS DISTINCT FROM
    (OLD.status,OLD.state_version,OLD.status_reason_code,OLD.exiting_at,OLD.exited_at,OLD.expelled_at,OLD.is_active,OLD.payment_status,OLD.payment_reference,OLD.amount_paid,OLD.paid_at,OLD.entry_requirement_version_id,OLD.admission_proposal_id,OLD.admission_decided_at)
 AND current_setting('microfams.group_membership_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_ENGINE_REQUIRED';END IF;RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION adopt_initial_group_entry_requirements(p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_entry_fee_amount_minor BIGINT,p_currency TEXT,p_required_identity_tier TEXT,p_eligibility_rules JSONB,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g groups;r UUID;setting TEXT;
BEGIN
 IF p_entry_fee_amount_minor<0 OR p_entry_fee_amount_minor>100000000000 OR upper(p_currency)<>'NGN' OR p_required_identity_tier NOT IN('none','nin_verified') OR jsonb_typeof(p_eligibility_rules)<>'object' OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_ENTRY_REQUIREMENT_INVALID';END IF;
 SELECT requirement_version_id INTO r FROM group_entry_requirement_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;IF FOUND THEN RETURN r;END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
 SELECT * INTO g FROM groups WHERE id=p_group_id AND organization_id=p_organization_id AND lifecycle_state='active' FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND';END IF;
 IF g.current_constitution_id IS NULL OR EXISTS(SELECT 1 FROM group_entry_requirement_versions WHERE group_id=p_group_id) THEN RAISE EXCEPTION 'GROUP_ENTRY_REQUIREMENT_ALREADY_EXISTS';END IF;
 setting:=current_setting('microfams.group_membership_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);
 INSERT INTO group_entry_requirement_versions(organization_id,group_id,constitution_id,version,state,entry_fee_amount_minor,currency,required_identity_tier,eligibility_rules,capacity_limit,effective_from,created_by,created_at) VALUES(p_organization_id,p_group_id,g.current_constitution_id,1,'effective',p_entry_fee_amount_minor,'NGN',p_required_identity_tier,p_eligibility_rules,g.max_members,p_occurred_at,p_actor_id,p_occurred_at) RETURNING id INTO r;
 INSERT INTO group_entry_requirement_events(organization_id,group_id,requirement_version_id,actor_id,event_type,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,r,p_actor_id,'ENTRY_REQUIREMENTS_ADOPTED',p_correlation_id,jsonb_build_object('amount_minor',p_entry_fee_amount_minor,'currency','NGN','identity_tier',p_required_identity_tier,'capacity_limit',g.max_members),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);RETURN r;
END $$;

CREATE OR REPLACE FUNCTION create_group_membership_invitation(p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_intended_user_id UUID,p_token_digest TEXT,p_expires_at TIMESTAMPTZ,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g groups;i UUID;r UUID;setting TEXT;
BEGIN
 IF p_token_digest!~'^[0-9a-f]{64}$' OR p_expires_at<=p_occurred_at OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_INVITATION_COMMAND_INVALID';END IF;
 SELECT invitation_id INTO i FROM group_membership_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;IF FOUND THEN RETURN jsonb_build_object('invitation_id',i,'created',FALSE);END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);SELECT * INTO g FROM groups WHERE id=p_group_id AND organization_id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND';END IF;IF g.lifecycle_state<>'active' THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_MEMBERS';END IF;
 SELECT id INTO r FROM group_entry_requirement_versions WHERE group_id=p_group_id AND organization_id=p_organization_id AND state='effective';IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ENTRY_REQUIREMENT_REQUIRED';END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization_id AND user_id=p_intended_user_id AND status='active') THEN RAISE EXCEPTION 'INVITEE_TENANT_MEMBERSHIP_REQUIRED';END IF;
 IF EXISTS(SELECT 1 FROM group_members WHERE group_id=p_group_id AND user_id=p_intended_user_id) THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_ALREADY_EXISTS';END IF;
 setting:=current_setting('microfams.group_membership_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);UPDATE group_membership_invitations SET state='expired' WHERE group_id=p_group_id AND intended_user_id=p_intended_user_id AND state='pending' AND expires_at<=p_occurred_at;
 INSERT INTO group_membership_invitations(organization_id,group_id,constitution_id,entry_requirement_version_id,intended_user_id,token_digest,expires_at,invited_by,created_at) VALUES(p_organization_id,p_group_id,g.current_constitution_id,r,p_intended_user_id,p_token_digest,p_expires_at,p_actor_id,p_occurred_at) RETURNING id INTO i;
 INSERT INTO group_membership_events(organization_id,group_id,invitation_id,actor_id,event_type,from_state,to_state,reason_code,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,i,p_actor_id,'INVITATION_CREATED',NULL,'pending','MEMBERSHIP_INVITED',p_correlation_id,jsonb_build_object('entry_requirement_version_id',r),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);RETURN jsonb_build_object('invitation_id',i,'created',TRUE);
END $$;

CREATE OR REPLACE FUNCTION accept_group_membership_invitation(p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_token_digest TEXT,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE i group_membership_invitations;r group_entry_requirement_versions;m UUID;setting TEXT;
BEGIN
 IF p_token_digest!~'^[0-9a-f]{64}$' OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_INVITATION_COMMAND_INVALID';END IF;SELECT membership_id INTO m FROM group_membership_events WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;IF FOUND THEN RETURN m;END IF;
 SELECT * INTO i FROM group_membership_invitations WHERE organization_id=p_organization_id AND group_id=p_group_id AND token_digest=p_token_digest FOR UPDATE;IF NOT FOUND OR i.intended_user_id<>p_actor_id THEN RAISE EXCEPTION 'GROUP_INVITATION_NOT_FOUND';END IF;
 IF i.state<>'pending' OR i.expires_at<=p_occurred_at THEN RAISE EXCEPTION 'GROUP_INVITATION_UNAVAILABLE';END IF;IF NOT EXISTS(SELECT 1 FROM groups WHERE id=i.group_id AND organization_id=p_organization_id AND lifecycle_state='active') THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_MEMBERS';END IF;
 SELECT * INTO r FROM group_entry_requirement_versions WHERE id=i.entry_requirement_version_id AND organization_id=p_organization_id AND group_id=i.group_id;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ENTRY_REQUIREMENT_REQUIRED';END IF;
 IF (SELECT count(*) FROM group_members WHERE group_id=i.group_id AND status IN('applicant','pending_payment','active','suspended','exiting')) >= r.capacity_limit THEN RAISE EXCEPTION 'GROUP_CAPACITY_REACHED';END IF;
 setting:=current_setting('microfams.group_membership_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);
 INSERT INTO group_members(organization_id,group_id,user_id,status,is_active,invited_at,entry_requirement_version_id) VALUES(p_organization_id,i.group_id,p_actor_id,'applicant',FALSE,i.created_at,i.entry_requirement_version_id) RETURNING id INTO m;
 UPDATE group_membership_invitations SET state='accepted',accepted_at=p_occurred_at WHERE id=i.id;
 INSERT INTO group_membership_events(organization_id,group_id,membership_id,invitation_id,actor_id,event_type,from_state,to_state,reason_code,correlation_id,evidence,occurred_at) VALUES(p_organization_id,i.group_id,m,i.id,p_actor_id,'INVITATION_ACCEPTED','invited','applicant','INVITATION_ACCEPTED',p_correlation_id,jsonb_build_object('entry_requirement_version_id',i.entry_requirement_version_id),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);RETURN m;
END $$;

CREATE OR REPLACE FUNCTION execute_group_membership_admission(p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_membership_id UUID,p_proposal_id UUID,p_expected_membership_version INTEGER,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS group_members LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE m group_members;p group_proposals;r group_entry_requirement_versions;g groups;setting TEXT;psetting TEXT;target TEXT;
BEGIN
 SELECT gm.* INTO m FROM group_membership_events e JOIN group_members gm ON gm.id=e.membership_id WHERE e.organization_id=p_organization_id AND e.correlation_id=p_correlation_id;IF FOUND THEN RETURN m;END IF;
 PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);SELECT * INTO m FROM group_members WHERE id=p_membership_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_NOT_FOUND';END IF;
 IF m.status<>'applicant' OR m.state_version<>p_expected_membership_version THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_VERSION_CONFLICT';END IF;
 SELECT * INTO p FROM group_proposals WHERE id=p_proposal_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND';END IF;
 IF p.state<>'approved' OR p.proposal_type<>'membership_action' OR p.execution_payload->>'action'<>'admit' OR p.execution_payload->>'membership_id'<>m.id::TEXT OR NOT(m.user_id=ANY(p.conflict_user_ids)) THEN RAISE EXCEPTION 'GROUP_ADMISSION_DECISION_INVALID';END IF;
 SELECT * INTO r FROM group_entry_requirement_versions WHERE id=m.entry_requirement_version_id AND organization_id=p_organization_id AND group_id=p_group_id;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ENTRY_REQUIREMENT_REQUIRED';END IF;
 IF r.constitution_id<>p.constitution_id THEN RAISE EXCEPTION 'GROUP_ADMISSION_RULE_VERSION_MISMATCH';END IF;
 IF r.required_identity_tier='nin_verified' AND NOT EXISTS(SELECT 1 FROM users WHERE id=m.user_id AND nin_verified) THEN RAISE EXCEPTION 'GROUP_ADMISSION_IDENTITY_REQUIRED';END IF;
 SELECT * INTO g FROM groups WHERE id=p_group_id AND organization_id=p_organization_id AND lifecycle_state='active' FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_MEMBERS';END IF;
 IF (SELECT count(*) FROM group_members WHERE group_id=p_group_id AND id<>m.id AND status IN('pending_payment','active','suspended','exiting'))>=r.capacity_limit THEN RAISE EXCEPTION 'GROUP_CAPACITY_REACHED';END IF;
 target:=CASE WHEN r.entry_fee_amount_minor=0 THEN 'active' ELSE 'pending_payment' END;setting:=current_setting('microfams.group_membership_engine',TRUE);psetting:=current_setting('microfams.group_proposal_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);PERFORM set_config('microfams.group_proposal_engine','on',TRUE);
 UPDATE group_proposals SET state='executing',state_version=state_version+1,updated_at=p_occurred_at WHERE id=p.id;
 UPDATE group_members SET status=target,is_active=(target='active'),payment_status=CASE WHEN target='active' THEN 'paid' ELSE 'pending' END,amount_paid=CASE WHEN target='active' THEN 0 ELSE amount_paid END,paid_at=CASE WHEN target='active' THEN p_occurred_at ELSE paid_at END,state_version=state_version+1,status_reason_code='ADMISSION_APPROVED',admission_proposal_id=p.id,admission_decided_at=p_occurred_at WHERE id=m.id RETURNING * INTO m;
 IF target='active' THEN UPDATE groups SET member_count=member_count+1 WHERE id=p_group_id;END IF;
 UPDATE group_proposals SET state='executed',state_version=state_version+1,updated_at=p_occurred_at WHERE id=p.id;
 INSERT INTO group_proposal_events(organization_id,group_id,proposal_id,actor_id,event_type,from_state,to_state,resource_id,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,p.id,p_actor_id,'PROPOSAL_EXECUTED','approved','executed',m.id,p_correlation_id,jsonb_build_object('membership_id',m.id,'membership_state',target),p_occurred_at);
 INSERT INTO group_membership_events(organization_id,group_id,membership_id,actor_id,event_type,from_state,to_state,reason_code,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,m.id,p_actor_id,'ADMISSION_EXECUTED','applicant',target,'ADMISSION_APPROVED',p_correlation_id,jsonb_build_object('proposal_id',p.id,'entry_requirement_version_id',r.id,'amount_minor',r.entry_fee_amount_minor),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);PERFORM set_config('microfams.group_proposal_engine',COALESCE(psetting,''),TRUE);RETURN m;
END $$;

CREATE OR REPLACE FUNCTION activate_paid_group_membership(p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_membership_id UUID,p_payment_id UUID,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS group_members LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE m group_members;r group_entry_requirement_versions;p payments;a group_membership_payment_allocations;setting TEXT;customer UUID;income UUID;journal UUID;lines JSONB;was_pending BOOLEAN;
BEGIN
 SELECT gm.* INTO m FROM group_membership_events e JOIN group_members gm ON gm.id=e.membership_id WHERE e.organization_id=p_organization_id AND e.correlation_id=p_correlation_id;IF FOUND THEN RETURN m;END IF;
 SELECT * INTO m FROM group_members WHERE id=p_membership_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;IF NOT FOUND OR m.user_id<>p_actor_id THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_NOT_FOUND';END IF;
 SELECT * INTO a FROM group_membership_payment_allocations WHERE payment_id=p_payment_id;IF FOUND THEN RETURN m;END IF;
 IF NOT(m.status='pending_payment' OR (m.status='active' AND m.payment_status='failed')) THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_PAYMENT_NOT_DUE';END IF;was_pending:=m.status='pending_payment';
 SELECT * INTO r FROM group_entry_requirement_versions WHERE id=m.entry_requirement_version_id AND organization_id=p_organization_id AND group_id=p_group_id;IF NOT FOUND OR r.entry_fee_amount_minor<=0 THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_PAYMENT_NOT_DUE';END IF;
 SELECT * INTO p FROM payments WHERE id=p_payment_id AND organization_id=p_organization_id AND source_type='group_membership' AND source_id=m.id AND payer_id=m.user_id AND state='succeeded' AND success_journal_entry_id IS NOT NULL FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_PAYMENT_UNVERIFIED';END IF;
 IF p.amount_minor<>r.entry_fee_amount_minor OR p.currency<>r.currency THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_PAYMENT_MISMATCH';END IF;
 IF r.required_identity_tier='nin_verified' AND NOT EXISTS(SELECT 1 FROM users WHERE id=m.user_id AND nin_verified) THEN RAISE EXCEPTION 'GROUP_ADMISSION_IDENTITY_REQUIRED';END IF;
 customer:=ensure_wallet_system_account(p_organization_id,'PAYMENT.CUSTOMER_FUNDS','Inbound customer funds pending allocation','liability','credit');income:=ensure_wallet_system_account(p_organization_id,'GROUP.'||upper(substr(md5(p_group_id::TEXT),1,16))||'.MEMBERSHIP_FEES','Group membership fee income','revenue','credit');
 lines:=jsonb_build_array(jsonb_build_object('account_id',customer,'line_number',1,'side','debit','amount_minor',p.amount_minor,'memo','Allocate verified membership fee'),jsonb_build_object('account_id',income,'line_number',2,'side','credit','amount_minor',p.amount_minor,'memo','Recognize group membership fee'));
 journal:=post_wallet_journal(p_organization_id,'group.membership_fee',p.id::TEXT,'Allocate verified group membership fee',lines);
 setting:=current_setting('microfams.group_membership_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);
 INSERT INTO group_membership_payment_allocations(organization_id,group_id,membership_id,entry_requirement_version_id,payment_id,amount_minor,currency,allocation_journal_entry_id,allocated_at) VALUES(p_organization_id,p_group_id,m.id,r.id,p.id,p.amount_minor,p.currency,journal,p_occurred_at);
 UPDATE group_members SET status='active',is_active=TRUE,payment_status='paid',payment_reference=p.internal_reference,amount_paid=p.amount_minor/100.0,paid_at=p_occurred_at,state_version=state_version+1,status_reason_code='ENTRY_PAYMENT_CONFIRMED' WHERE id=m.id RETURNING * INTO m;
 IF was_pending THEN UPDATE groups SET member_count=member_count+1 WHERE id=p_group_id;END IF;
 INSERT INTO group_membership_events(organization_id,group_id,membership_id,actor_id,event_type,from_state,to_state,reason_code,correlation_id,evidence,occurred_at) VALUES(p_organization_id,p_group_id,m.id,p_actor_id,'ENTRY_PAYMENT_CONFIRMED',CASE WHEN was_pending THEN 'pending_payment' ELSE 'active' END,'active','ENTRY_PAYMENT_CONFIRMED',p_correlation_id,jsonb_build_object('payment_id',p.id,'amount_minor',p.amount_minor,'currency',p.currency,'journal_entry_id',journal),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);RETURN m;
END $$;

CREATE OR REPLACE FUNCTION reverse_group_membership_payment_allocation(p_payment_id UUID,p_reversal_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()) RETURNS group_members LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE a group_membership_payment_allocations;m group_members;rev payment_reversals;setting TEXT;customer UUID;income UUID;journal UUID;lines JSONB;
BEGIN
 SELECT * INTO a FROM group_membership_payment_allocations WHERE payment_id=p_payment_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_ALLOCATION_NOT_FOUND';END IF;
 SELECT * INTO m FROM group_members WHERE id=a.membership_id FOR UPDATE;IF a.state='reversed' THEN RETURN m;END IF;
 SELECT * INTO rev FROM payment_reversals WHERE id=p_reversal_id AND payment_id=p_payment_id AND amount_minor=a.amount_minor;IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_REVERSAL_UNVERIFIED';END IF;
 customer:=ensure_wallet_system_account(a.organization_id,'PAYMENT.CUSTOMER_FUNDS','Inbound customer funds pending allocation','liability','credit');income:=ensure_wallet_system_account(a.organization_id,'GROUP.'||upper(substr(md5(a.group_id::TEXT),1,16))||'.MEMBERSHIP_FEES','Group membership fee income','revenue','credit');
 lines:=jsonb_build_array(jsonb_build_object('account_id',income,'line_number',1,'side','debit','amount_minor',a.amount_minor,'memo','Reverse membership fee income'),jsonb_build_object('account_id',customer,'line_number',2,'side','credit','amount_minor',a.amount_minor,'memo','Restore customer funds allocation'));
 journal:=post_wallet_journal(a.organization_id,'group.membership_fee_reversal',rev.id::TEXT,'Reverse group membership fee allocation',lines);
 setting:=current_setting('microfams.group_membership_engine',TRUE);PERFORM set_config('microfams.group_membership_engine','on',TRUE);
 UPDATE group_membership_payment_allocations SET state='reversed',reversal_id=rev.id,reversal_journal_entry_id=journal,reversed_at=p_occurred_at WHERE id=a.id;
 UPDATE group_members SET payment_status='failed',state_version=state_version+1,status_reason_code='ENTRY_PAYMENT_REVERSED' WHERE id=m.id RETURNING * INTO m;
 INSERT INTO group_membership_events(organization_id,group_id,membership_id,actor_id,event_type,from_state,to_state,reason_code,correlation_id,evidence,occurred_at) VALUES(a.organization_id,a.group_id,m.id,NULL,'ENTRY_PAYMENT_REVERSED',m.status,m.status,'ENTRY_PAYMENT_REVERSED',rev.id,jsonb_build_object('payment_id',p_payment_id,'reversal_id',rev.id,'journal_entry_id',journal),p_occurred_at);
 PERFORM set_config('microfams.group_membership_engine',COALESCE(setting,''),TRUE);RETURN m;
END $$;

DROP FUNCTION IF EXISTS confirm_group_payment_transaction(UUID);
DO $$DECLARE t TEXT;BEGIN FOREACH t IN ARRAY ARRAY['group_entry_requirement_versions','group_entry_requirement_events','group_membership_payment_allocations'] LOOP EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I',t);EXECUTE format('CREATE POLICY tenant_read ON %I FOR SELECT USING(has_active_organization_membership(organization_id))',t);EXECUTE format('REVOKE ALL ON %I FROM PUBLIC,anon,authenticated',t);EXECUTE format('GRANT SELECT ON %I TO service_role',t);EXECUTE format('REVOKE INSERT,UPDATE,DELETE ON %I FROM service_role',t);END LOOP;END $$;
REVOKE ALL ON FUNCTION adopt_initial_group_entry_requirements(UUID,UUID,UUID,BIGINT,TEXT,TEXT,JSONB,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION execute_group_membership_admission(UUID,UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION activate_paid_group_membership(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION reverse_group_membership_payment_allocation(UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION adopt_initial_group_entry_requirements(UUID,UUID,UUID,BIGINT,TEXT,TEXT,JSONB,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION execute_group_membership_admission(UUID,UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION activate_paid_group_membership(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION reverse_group_membership_payment_allocation(UUID,UUID,TIMESTAMPTZ) TO service_role;
