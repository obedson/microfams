-- GT-02C: noticed, proposal-backed member discipline and independent appeals.
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS group_member_discipline_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  target_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  proposed_action TEXT NOT NULL CHECK (proposed_action IN ('suspend', 'expel')),
  state TEXT NOT NULL DEFAULT 'notice_issued' CHECK (state IN (
    'notice_issued', 'voting', 'closed_no_action', 'decided', 'appealed', 'resolved'
  )),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  public_notice TEXT NOT NULL CHECK (length(trim(public_notice)) BETWEEN 20 AND 1000),
  private_evidence_refs JSONB NOT NULL CHECK (
    jsonb_typeof(private_evidence_refs) = 'array'
    AND jsonb_array_length(private_evidence_refs) BETWEEN 1 AND 100
  ),
  notice_issued_at TIMESTAMPTZ NOT NULL,
  response_due_at TIMESTAMPTZ NOT NULL,
  appeal_window_days INTEGER NOT NULL CHECK (appeal_window_days BETWEEN 1 AND 90),
  proposal_id UUID UNIQUE REFERENCES group_proposals(id) ON DELETE RESTRICT,
  decided_at TIMESTAMPTZ,
  decision_executed_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  appeal_deadline TIMESTAMPTZ,
  resolution_outcome TEXT CHECK (resolution_outcome IN (
    'no_action', 'suspended', 'expelled', 'appeal_upheld', 'reinstated'
  )),
  created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  CHECK (response_due_at >= notice_issued_at + INTERVAL '24 hours'),
  CHECK (response_due_at <= notice_issued_at + INTERVAL '30 days'),
  CHECK ((state IN ('decided', 'appealed', 'resolved')) = (appeal_deadline IS NOT NULL)
    OR state = 'closed_no_action'),
  CHECK ((state IN ('closed_no_action', 'decided', 'appealed', 'resolved'))
    = (decided_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_group_discipline_case_tenant
  ON group_member_discipline_cases(organization_id, group_id, membership_id, state);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_open_discipline_case
  ON group_member_discipline_cases(membership_id)
  WHERE state IN ('notice_issued', 'voting', 'decided', 'appealed');

CREATE TABLE IF NOT EXISTS group_member_discipline_appeals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  case_id UUID NOT NULL UNIQUE REFERENCES group_member_discipline_cases(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  appellant_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  state TEXT NOT NULL DEFAULT 'filed' CHECK (state IN ('filed', 'upheld', 'reinstated')),
  grounds TEXT NOT NULL CHECK (length(trim(grounds)) BETWEEN 20 AND 4000),
  evidence_refs JSONB NOT NULL DEFAULT '[]'::JSONB CHECK (
    jsonb_typeof(evidence_refs) = 'array' AND jsonb_array_length(evidence_refs) <= 100
  ),
  filed_at TIMESTAMPTZ NOT NULL,
  decided_at TIMESTAMPTZ,
  decided_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  decision_reason_code TEXT CHECK (
    decision_reason_code IS NULL OR decision_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'
  ),
  decision_evidence_refs JSONB CHECK (
    decision_evidence_refs IS NULL OR (
      jsonb_typeof(decision_evidence_refs) = 'array'
      AND jsonb_array_length(decision_evidence_refs) BETWEEN 1 AND 100
    )
  ),
  CHECK ((state = 'filed') = (decided_at IS NULL)),
  CHECK ((state = 'filed') = (decided_by IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_group_discipline_appeal_tenant
  ON group_member_discipline_appeals(organization_id, group_id, state, filed_at);

CREATE TABLE IF NOT EXISTS group_member_discipline_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  case_id UUID NOT NULL REFERENCES group_member_discipline_cases(id) ON DELETE RESTRICT,
  appeal_id UUID REFERENCES group_member_discipline_appeals(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  from_state TEXT,
  to_state TEXT,
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  correlation_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  UNIQUE (organization_id, correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_discipline_event_tenant
  ON group_member_discipline_events(organization_id, group_id, case_id, occurred_at);

ALTER TABLE group_members
  ADD COLUMN IF NOT EXISTS current_discipline_case_id UUID
    REFERENCES group_member_discipline_cases(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION protect_group_discipline_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_discipline_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'GROUP_DISCIPLINE_ENGINE_REQUIRED';
END;
$$;
DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'group_member_discipline_cases',
    'group_member_discipline_appeals',
    'group_member_discipline_events'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS protect_group_discipline_evidence ON %I', table_name);
    EXECUTE format(
      'CREATE TRIGGER protect_group_discipline_evidence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION protect_group_discipline_evidence()',
      table_name
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION protect_group_membership_state() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF (
    NEW.status, NEW.state_version, NEW.status_reason_code, NEW.exiting_at,
    NEW.exited_at, NEW.expelled_at, NEW.is_active, NEW.payment_status,
    NEW.payment_reference, NEW.amount_paid, NEW.paid_at,
    NEW.entry_requirement_version_id, NEW.admission_proposal_id,
    NEW.admission_decided_at, NEW.current_discipline_case_id, NEW.suspended_at
  ) IS DISTINCT FROM (
    OLD.status, OLD.state_version, OLD.status_reason_code, OLD.exiting_at,
    OLD.exited_at, OLD.expelled_at, OLD.is_active, OLD.payment_status,
    OLD.payment_reference, OLD.amount_paid, OLD.paid_at,
    OLD.entry_requirement_version_id, OLD.admission_proposal_id,
    OLD.admission_decided_at, OLD.current_discipline_case_id, OLD.suspended_at
  ) AND current_setting('microfams.group_membership_engine', TRUE) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'GROUP_MEMBERSHIP_ENGINE_REQUIRED';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_group_discipline_proposal_transition() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  discipline_case group_member_discipline_cases;
  prior_setting TEXT;
  action_name TEXT;
  case_identifier UUID;
BEGIN
  IF NEW.proposal_type <> 'membership_action' THEN RETURN NEW; END IF;
  action_name := NEW.execution_payload ->> 'action';
  IF action_name NOT IN ('suspend', 'expel') THEN RETURN NEW; END IF;
  BEGIN
    case_identifier := (NEW.execution_payload ->> 'discipline_case_id')::UUID;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'GROUP_DISCIPLINE_PROPOSAL_INVALID';
  END;
  SELECT * INTO discipline_case FROM group_member_discipline_cases
  WHERE id = case_identifier
    AND organization_id = NEW.organization_id
    AND group_id = NEW.group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_CASE_NOT_FOUND'; END IF;
  IF discipline_case.proposal_id <> NEW.id
    OR discipline_case.proposed_action <> action_name
    OR NEW.execution_payload ->> 'membership_id' <> discipline_case.membership_id::TEXT
    OR discipline_case.constitution_id <> NEW.constitution_id
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_PROPOSAL_INVALID'; END IF;
  IF NOT (discipline_case.target_user_id = ANY(NEW.conflict_user_ids))
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_TARGET_CONFLICT_REQUIRED'; END IF;

  prior_setting := current_setting('microfams.group_discipline_engine', TRUE);
  PERFORM set_config('microfams.group_discipline_engine', 'on', TRUE);
  IF OLD.state = 'draft' AND NEW.state = 'open' THEN
    IF discipline_case.state <> 'notice_issued'
      OR NEW.opened_at < discipline_case.response_due_at
    THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_RESPONSE_WINDOW_OPEN'; END IF;
    UPDATE group_member_discipline_cases
    SET state = 'voting', updated_at = NEW.opened_at
    WHERE id = discipline_case.id;
    INSERT INTO group_member_discipline_events(
      organization_id, group_id, case_id, membership_id, actor_id,
      event_type, from_state, to_state, reason_code, correlation_id,
      evidence, occurred_at
    ) VALUES (
      NEW.organization_id, NEW.group_id, discipline_case.id,
      discipline_case.membership_id, NEW.proposer_id, 'DISCIPLINE_VOTE_OPENED',
      'notice_issued', 'voting', discipline_case.reason_code,
      md5('discipline-open:' || NEW.id::TEXT)::UUID,
      jsonb_build_object('proposal_id', NEW.id), NEW.opened_at
    );
  ELSIF OLD.state IN ('draft', 'open')
    AND NEW.state IN ('rejected', 'expired', 'cancelled')
    AND discipline_case.state IN ('notice_issued', 'voting') THEN
    UPDATE group_member_discipline_cases SET
      state = 'closed_no_action', decided_at = COALESCE(NEW.decided_at, NEW.updated_at),
      resolution_outcome = 'no_action', updated_at = COALESCE(NEW.decided_at, NEW.updated_at)
    WHERE id = discipline_case.id;
    INSERT INTO group_member_discipline_events(
      organization_id, group_id, case_id, membership_id, actor_id,
      event_type, from_state, to_state, reason_code, correlation_id,
      evidence, occurred_at
    ) VALUES (
      NEW.organization_id, NEW.group_id, discipline_case.id,
      discipline_case.membership_id, NULL, 'DISCIPLINE_CLOSED_NO_ACTION',
      discipline_case.state, 'closed_no_action', discipline_case.reason_code,
      md5('discipline-closed:' || NEW.id::TEXT || ':' || NEW.state)::UUID,
      jsonb_build_object('proposal_id', NEW.id, 'proposal_state', NEW.state),
      COALESCE(NEW.decided_at, NEW.updated_at)
    );
  END IF;
  PERFORM set_config('microfams.group_discipline_engine', COALESCE(prior_setting, ''), TRUE);
  RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION require_group_discipline_case_for_proposal() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  discipline_case group_member_discipline_cases;
  case_identifier UUID;
  action_name TEXT;
BEGIN
  IF NEW.proposal_type <> 'membership_action' THEN RETURN NEW; END IF;
  action_name := NEW.execution_payload ->> 'action';
  IF action_name NOT IN ('suspend', 'expel') THEN RETURN NEW; END IF;
  IF current_setting('microfams.group_discipline_engine', TRUE) IS DISTINCT FROM 'on'
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_CASE_REQUIRED'; END IF;
  BEGIN
    case_identifier := (NEW.execution_payload ->> 'discipline_case_id')::UUID;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'GROUP_DISCIPLINE_PROPOSAL_INVALID';
  END;
  SELECT * INTO discipline_case FROM group_member_discipline_cases
  WHERE id = case_identifier AND organization_id = NEW.organization_id
    AND group_id = NEW.group_id;
  IF NOT FOUND OR discipline_case.proposal_id IS NOT NULL
    OR discipline_case.proposed_action <> action_name
    OR NEW.execution_payload ->> 'membership_id' <> discipline_case.membership_id::TEXT
    OR discipline_case.constitution_id <> NEW.constitution_id
    OR NOT (discipline_case.target_user_id = ANY(NEW.conflict_user_ids))
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_PROPOSAL_INVALID'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS require_group_discipline_case_for_proposal ON group_proposals;
CREATE TRIGGER require_group_discipline_case_for_proposal
  BEFORE INSERT ON group_proposals
  FOR EACH ROW EXECUTE FUNCTION require_group_discipline_case_for_proposal();
DROP TRIGGER IF EXISTS enforce_group_discipline_proposal_transition ON group_proposals;
CREATE TRIGGER enforce_group_discipline_proposal_transition
  BEFORE UPDATE OF state ON group_proposals
  FOR EACH ROW EXECUTE FUNCTION enforce_group_discipline_proposal_transition();

CREATE OR REPLACE FUNCTION create_group_member_discipline_case(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_membership_id UUID,
  p_proposed_action TEXT,
  p_reason_code TEXT,
  p_public_notice TEXT,
  p_private_evidence_refs JSONB,
  p_response_due_at TIMESTAMPTZ,
  p_proposal_closes_at TIMESTAMPTZ,
  p_appeal_window_days INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  group_record groups;
  member_record group_members;
  existing_case UUID;
  expired_case group_member_discipline_cases;
  case_identifier UUID;
  proposal_identifier UUID;
  prior_setting TEXT;
BEGIN
  IF p_proposed_action NOT IN ('suspend', 'expel')
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    OR length(trim(COALESCE(p_public_notice, ''))) NOT BETWEEN 20 AND 1000
    OR jsonb_typeof(p_private_evidence_refs) <> 'array'
    OR jsonb_array_length(p_private_evidence_refs) NOT BETWEEN 1 AND 100
    OR p_response_due_at < p_occurred_at + INTERVAL '24 hours'
    OR p_response_due_at > p_occurred_at + INTERVAL '30 days'
    OR p_proposal_closes_at <= p_response_due_at
    OR p_proposal_closes_at > p_response_due_at + INTERVAL '30 days'
    OR p_appeal_window_days NOT BETWEEN 1 AND 90
    OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_COMMAND_INVALID'; END IF;

  SELECT case_id INTO existing_case FROM group_member_discipline_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id;
  IF FOUND THEN
    SELECT proposal_id INTO proposal_identifier
    FROM group_member_discipline_cases WHERE id = existing_case;
    RETURN jsonb_build_object(
      'case_id', existing_case, 'proposal_id', proposal_identifier, 'created', FALSE
    );
  END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO group_record FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id
    AND lifecycle_state = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_DISCIPLINE'; END IF;
  SELECT * INTO member_record FROM group_members
  WHERE id = p_membership_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_NOT_FOUND'; END IF;
  IF member_record.user_id = p_actor_id THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_SELF_CONFLICT'; END IF;
  IF (p_proposed_action = 'suspend' AND member_record.status <> 'active')
    OR (p_proposed_action = 'expel' AND member_record.status NOT IN ('active', 'suspended'))
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_STATE_CONFLICT'; END IF;

  prior_setting := current_setting('microfams.group_discipline_engine', TRUE);
  PERFORM set_config('microfams.group_discipline_engine', 'on', TRUE);
  SELECT * INTO expired_case FROM group_member_discipline_cases
  WHERE membership_id = member_record.id AND state = 'decided'
    AND appeal_deadline < p_occurred_at FOR UPDATE;
  IF FOUND THEN
    UPDATE group_member_discipline_cases SET state = 'resolved', updated_at = p_occurred_at
    WHERE id = expired_case.id;
    INSERT INTO group_member_discipline_events(
      organization_id, group_id, case_id, membership_id, actor_id,
      event_type, from_state, to_state, reason_code, correlation_id,
      evidence, occurred_at
    ) VALUES (
      p_organization_id, p_group_id, expired_case.id, member_record.id, p_actor_id,
      'DISCIPLINE_APPEAL_WINDOW_EXPIRED', 'decided', 'resolved',
      expired_case.reason_code,
      md5('discipline-appeal-expired:' || expired_case.id::TEXT)::UUID,
      jsonb_build_object('appeal_deadline', expired_case.appeal_deadline), p_occurred_at
    );
  END IF;
  IF EXISTS (
    SELECT 1 FROM group_member_discipline_cases
    WHERE membership_id = member_record.id
      AND state IN ('notice_issued', 'voting', 'decided', 'appealed')
  ) THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_CASE_ALREADY_OPEN'; END IF;

  INSERT INTO group_member_discipline_cases(
    organization_id, group_id, membership_id, target_user_id, constitution_id,
    proposed_action, reason_code, public_notice, private_evidence_refs,
    notice_issued_at, response_due_at, appeal_window_days, created_by,
    created_at, updated_at
  ) VALUES (
    p_organization_id, p_group_id, member_record.id, member_record.user_id,
    group_record.current_constitution_id, p_proposed_action, p_reason_code,
    trim(p_public_notice), p_private_evidence_refs, p_occurred_at,
    p_response_due_at, p_appeal_window_days, p_actor_id, p_occurred_at, p_occurred_at
  ) RETURNING id INTO case_identifier;

  proposal_identifier := create_group_proposal(
    p_organization_id, p_group_id, p_actor_id, 'membership_action',
    left('Membership ' || p_proposed_action || ' review: ' || trim(p_public_notice), 500),
    p_private_evidence_refs,
    jsonb_build_object(
      'action', p_proposed_action,
      'membership_id', member_record.id,
      'discipline_case_id', case_identifier
    ),
    ARRAY[member_record.user_id], p_response_due_at, p_proposal_closes_at,
    md5('discipline-proposal:' || case_identifier::TEXT)::UUID, p_occurred_at
  );
  UPDATE group_member_discipline_cases SET proposal_id = proposal_identifier
  WHERE id = case_identifier;
  INSERT INTO group_member_discipline_events(
    organization_id, group_id, case_id, membership_id, actor_id, event_type,
    to_state, reason_code, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, case_identifier, member_record.id, p_actor_id,
    'DISCIPLINE_NOTICE_ISSUED', 'notice_issued', p_reason_code, p_correlation_id,
    jsonb_build_object(
      'action', p_proposed_action,
      'proposal_id', proposal_identifier,
      'response_due_at', p_response_due_at,
      'appeal_window_days', p_appeal_window_days
    ), p_occurred_at
  );
  PERFORM set_config('microfams.group_discipline_engine', COALESCE(prior_setting, ''), TRUE);
  RETURN jsonb_build_object(
    'case_id', case_identifier, 'proposal_id', proposal_identifier, 'created', TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION execute_group_member_discipline(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_case_id UUID,
  p_expected_membership_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_members
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  discipline_case group_member_discipline_cases;
  member_record group_members;
  proposal_record group_proposals;
  prior_discipline_setting TEXT;
  prior_membership_setting TEXT;
  prior_proposal_setting TEXT;
  prior_state TEXT;
  target_state TEXT;
BEGIN
  SELECT member.* INTO member_record
  FROM group_member_discipline_events event
  JOIN group_members member ON member.id = event.membership_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id;
  IF FOUND THEN RETURN member_record; END IF;
  IF p_expected_membership_version < 1 OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_COMMAND_INVALID'; END IF;
  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO discipline_case FROM group_member_discipline_cases
  WHERE id = p_case_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_CASE_NOT_FOUND'; END IF;
  SELECT * INTO member_record FROM group_members
  WHERE id = discipline_case.membership_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_NOT_FOUND'; END IF;
  IF member_record.state_version <> p_expected_membership_version
  THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_VERSION_CONFLICT'; END IF;
  SELECT * INTO proposal_record FROM group_proposals
  WHERE id = discipline_case.proposal_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND'; END IF;
  IF discipline_case.state <> 'voting'
    OR discipline_case.proposal_id <> proposal_record.id
    OR proposal_record.state <> 'approved'
    OR proposal_record.proposal_type <> 'membership_action'
    OR proposal_record.execution_payload ->> 'action' <> discipline_case.proposed_action
    OR proposal_record.execution_payload ->> 'membership_id' <> member_record.id::TEXT
    OR proposal_record.execution_payload ->> 'discipline_case_id' <> discipline_case.id::TEXT
    OR NOT (member_record.user_id = ANY(proposal_record.conflict_user_ids))
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_DECISION_INVALID'; END IF;
  IF (discipline_case.proposed_action = 'suspend' AND member_record.status <> 'active')
    OR (discipline_case.proposed_action = 'expel'
      AND member_record.status NOT IN ('active', 'suspended'))
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_STATE_CONFLICT'; END IF;

  prior_state := member_record.status;
  target_state := CASE discipline_case.proposed_action
    WHEN 'suspend' THEN 'suspended' ELSE 'expelled' END;
  prior_discipline_setting := current_setting('microfams.group_discipline_engine', TRUE);
  prior_membership_setting := current_setting('microfams.group_membership_engine', TRUE);
  prior_proposal_setting := current_setting('microfams.group_proposal_engine', TRUE);
  PERFORM set_config('microfams.group_discipline_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_membership_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_proposal_engine', 'on', TRUE);
  UPDATE group_proposals SET state = 'executing', state_version = state_version + 1,
    updated_at = p_occurred_at WHERE id = proposal_record.id;
  UPDATE group_members SET
    status = target_state,
    is_active = FALSE,
    state_version = state_version + 1,
    status_reason_code = discipline_case.reason_code,
    current_discipline_case_id = discipline_case.id,
    suspended_at = CASE WHEN target_state = 'suspended' THEN p_occurred_at ELSE suspended_at END,
    expelled_at = CASE WHEN target_state = 'expelled' THEN p_occurred_at ELSE expelled_at END
  WHERE id = member_record.id RETURNING * INTO member_record;
  IF prior_state = 'active' THEN
    UPDATE groups SET member_count = GREATEST(member_count - 1, 0)
    WHERE id = p_group_id;
  END IF;
  UPDATE group_member_discipline_cases SET
    state = 'decided', decided_at = p_occurred_at,
    decision_executed_by = p_actor_id,
    appeal_deadline = p_occurred_at
      + make_interval(days => discipline_case.appeal_window_days),
    resolution_outcome = target_state, updated_at = p_occurred_at
  WHERE id = discipline_case.id;
  UPDATE group_proposals SET state = 'executed', state_version = state_version + 1,
    updated_at = p_occurred_at WHERE id = proposal_record.id;
  INSERT INTO group_proposal_events(
    organization_id, group_id, proposal_id, actor_id, event_type, from_state,
    to_state, resource_id, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, proposal_record.id, p_actor_id,
    'PROPOSAL_EXECUTED', 'approved', 'executed', discipline_case.id,
    p_correlation_id,
    jsonb_build_object('discipline_case_id', discipline_case.id, 'membership_state', target_state),
    p_occurred_at
  );
  INSERT INTO group_membership_events(
    organization_id, group_id, membership_id, actor_id, event_type, from_state,
    to_state, reason_code, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, member_record.id, p_actor_id,
    CASE target_state WHEN 'suspended' THEN 'MEMBER_SUSPENDED' ELSE 'MEMBER_EXPELLED' END,
    prior_state, target_state, discipline_case.reason_code, p_correlation_id,
    jsonb_build_object(
      'discipline_case_id', discipline_case.id,
      'proposal_id', proposal_record.id,
      'appeal_deadline', p_occurred_at
        + make_interval(days => discipline_case.appeal_window_days)
    ), p_occurred_at
  );
  INSERT INTO group_member_discipline_events(
    organization_id, group_id, case_id, membership_id, actor_id, event_type,
    from_state, to_state, reason_code, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, discipline_case.id, member_record.id,
    p_actor_id, 'DISCIPLINE_DECISION_EXECUTED', 'voting', 'decided',
    discipline_case.reason_code, p_correlation_id,
    jsonb_build_object('proposal_id', proposal_record.id, 'membership_state', target_state),
    p_occurred_at
  );
  PERFORM set_config('microfams.group_discipline_engine', COALESCE(prior_discipline_setting, ''), TRUE);
  PERFORM set_config('microfams.group_membership_engine', COALESCE(prior_membership_setting, ''), TRUE);
  PERFORM set_config('microfams.group_proposal_engine', COALESCE(prior_proposal_setting, ''), TRUE);
  RETURN member_record;
END;
$$;

CREATE OR REPLACE FUNCTION file_group_member_discipline_appeal(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_case_id UUID,
  p_grounds TEXT,
  p_evidence_refs JSONB,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  discipline_case group_member_discipline_cases;
  appeal_identifier UUID;
  prior_setting TEXT;
BEGIN
  IF length(trim(COALESCE(p_grounds, ''))) NOT BETWEEN 20 AND 4000
    OR jsonb_typeof(p_evidence_refs) <> 'array'
    OR jsonb_array_length(p_evidence_refs) > 100
    OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_INVALID'; END IF;
  SELECT appeal_id INTO appeal_identifier FROM group_member_discipline_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id;
  IF FOUND THEN RETURN appeal_identifier; END IF;
  SELECT * INTO discipline_case FROM group_member_discipline_cases
  WHERE id = p_case_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND OR discipline_case.target_user_id <> p_actor_id
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_CASE_NOT_FOUND'; END IF;
  IF discipline_case.state <> 'decided'
    OR p_occurred_at > discipline_case.appeal_deadline
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_UNAVAILABLE'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_members WHERE id = discipline_case.membership_id
      AND user_id = p_actor_id AND organization_id = p_organization_id
      AND group_id = p_group_id AND status IN ('suspended', 'expelled')
  ) THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_UNAVAILABLE'; END IF;
  prior_setting := current_setting('microfams.group_discipline_engine', TRUE);
  PERFORM set_config('microfams.group_discipline_engine', 'on', TRUE);
  INSERT INTO group_member_discipline_appeals(
    organization_id, group_id, case_id, membership_id, appellant_id,
    grounds, evidence_refs, filed_at
  ) VALUES (
    p_organization_id, p_group_id, discipline_case.id,
    discipline_case.membership_id, p_actor_id, trim(p_grounds),
    p_evidence_refs, p_occurred_at
  ) RETURNING id INTO appeal_identifier;
  UPDATE group_member_discipline_cases SET state = 'appealed', updated_at = p_occurred_at
  WHERE id = discipline_case.id;
  INSERT INTO group_member_discipline_events(
    organization_id, group_id, case_id, appeal_id, membership_id, actor_id,
    event_type, from_state, to_state, reason_code, correlation_id,
    evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, discipline_case.id, appeal_identifier,
    discipline_case.membership_id, p_actor_id, 'DISCIPLINE_APPEAL_FILED',
    'decided', 'appealed', 'MEMBER_APPEAL_FILED', p_correlation_id,
    jsonb_build_object('appeal_deadline', discipline_case.appeal_deadline),
    p_occurred_at
  );
  PERFORM set_config('microfams.group_discipline_engine', COALESCE(prior_setting, ''), TRUE);
  RETURN appeal_identifier;
END;
$$;

CREATE OR REPLACE FUNCTION decide_group_member_discipline_appeal(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_appeal_id UUID,
  p_outcome TEXT,
  p_reason_code TEXT,
  p_decision_evidence_refs JSONB,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_members
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  appeal_record group_member_discipline_appeals;
  discipline_case group_member_discipline_cases;
  member_record group_members;
  proposal_record group_proposals;
  prior_discipline_setting TEXT;
  prior_membership_setting TEXT;
BEGIN
  SELECT member.* INTO member_record
  FROM group_member_discipline_events event
  JOIN group_members member ON member.id = event.membership_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id;
  IF FOUND THEN RETURN member_record; END IF;
  IF p_outcome NOT IN ('uphold', 'reinstate')
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    OR jsonb_typeof(p_decision_evidence_refs) <> 'array'
    OR jsonb_array_length(p_decision_evidence_refs) NOT BETWEEN 1 AND 100
    OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_DECISION_INVALID'; END IF;
  SELECT * INTO appeal_record FROM group_member_discipline_appeals
  WHERE id = p_appeal_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_NOT_FOUND'; END IF;
  SELECT * INTO discipline_case FROM group_member_discipline_cases
  WHERE id = appeal_record.case_id FOR UPDATE;
  SELECT * INTO member_record FROM group_members
  WHERE id = appeal_record.membership_id FOR UPDATE;
  SELECT * INTO proposal_record FROM group_proposals
  WHERE id = discipline_case.proposal_id;
  IF appeal_record.state <> 'filed' OR discipline_case.state <> 'appealed'
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_UNAVAILABLE'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships tenant_member
    JOIN groups group_record ON group_record.id = p_group_id
      AND group_record.organization_id = tenant_member.organization_id
    WHERE tenant_member.organization_id = p_organization_id
      AND tenant_member.user_id = p_actor_id
      AND tenant_member.status = 'active'
      AND (
        tenant_member.role IN ('owner', 'admin')
        OR tenant_member.permissions @> ARRAY['groups.membership.appeals.decide']
      )
  ) THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_PERMISSION_DENIED'; END IF;
  IF p_actor_id IN (
      discipline_case.target_user_id, discipline_case.created_by,
      discipline_case.decision_executed_by, proposal_record.proposer_id
    ) OR EXISTS (
      SELECT 1 FROM group_vote_history
      WHERE proposal_id = proposal_record.id AND voter_id = p_actor_id
        AND is_current
    )
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_APPEAL_REVIEWER_CONFLICT'; END IF;
  IF member_record.status <> discipline_case.resolution_outcome
  THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_STATE_CONFLICT'; END IF;
  IF p_outcome = 'reinstate' AND NOT EXISTS (
    SELECT 1 FROM groups WHERE id = p_group_id
      AND organization_id = p_organization_id
      AND lifecycle_state IN ('active', 'suspended')
  ) THEN RAISE EXCEPTION 'GROUP_DISCIPLINE_REINSTATEMENT_UNAVAILABLE'; END IF;

  prior_discipline_setting := current_setting('microfams.group_discipline_engine', TRUE);
  prior_membership_setting := current_setting('microfams.group_membership_engine', TRUE);
  PERFORM set_config('microfams.group_discipline_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_membership_engine', 'on', TRUE);
  IF p_outcome = 'reinstate' THEN
    UPDATE group_members SET
      status = 'active', is_active = TRUE, state_version = state_version + 1,
      status_reason_code = 'DISCIPLINE_APPEAL_REINSTATED',
      current_discipline_case_id = NULL, suspended_at = NULL
    WHERE id = member_record.id RETURNING * INTO member_record;
    UPDATE groups SET member_count = member_count + 1 WHERE id = p_group_id;
    INSERT INTO group_membership_events(
      organization_id, group_id, membership_id, actor_id, event_type,
      from_state, to_state, reason_code, correlation_id, evidence, occurred_at
    ) VALUES (
      p_organization_id, p_group_id, member_record.id, p_actor_id,
      'MEMBER_REINSTATED', discipline_case.resolution_outcome, 'active',
      p_reason_code, p_correlation_id,
      jsonb_build_object('discipline_case_id', discipline_case.id, 'appeal_id', appeal_record.id),
      p_occurred_at
    );
  END IF;
  UPDATE group_member_discipline_appeals SET
    state = CASE p_outcome WHEN 'uphold' THEN 'upheld' ELSE 'reinstated' END,
    decided_at = p_occurred_at, decided_by = p_actor_id,
    decision_reason_code = p_reason_code,
    decision_evidence_refs = p_decision_evidence_refs
  WHERE id = appeal_record.id;
  UPDATE group_member_discipline_cases SET
    state = 'resolved',
    resolution_outcome = CASE p_outcome
      WHEN 'uphold' THEN 'appeal_upheld' ELSE 'reinstated' END,
    updated_at = p_occurred_at
  WHERE id = discipline_case.id;
  INSERT INTO group_member_discipline_events(
    organization_id, group_id, case_id, appeal_id, membership_id, actor_id,
    event_type, from_state, to_state, reason_code, correlation_id,
    evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, discipline_case.id, appeal_record.id,
    member_record.id, p_actor_id,
    CASE p_outcome WHEN 'uphold' THEN 'DISCIPLINE_APPEAL_UPHELD'
      ELSE 'DISCIPLINE_APPEAL_REINSTATED' END,
    'appealed', 'resolved', p_reason_code, p_correlation_id,
    jsonb_build_object('outcome', p_outcome), p_occurred_at
  );
  PERFORM set_config('microfams.group_discipline_engine', COALESCE(prior_discipline_setting, ''), TRUE);
  PERFORM set_config('microfams.group_membership_engine', COALESCE(prior_membership_setting, ''), TRUE);
  RETURN member_record;
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(
    COALESCE(permissions, '{}') || ARRAY[
      'groups.membership.discipline.manage',
      'groups.membership.appeals.decide'
    ]
  ) permission
) WHERE role IN ('owner', 'admin');

DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'group_member_discipline_cases',
    'group_member_discipline_appeals',
    'group_member_discipline_events'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT USING (has_active_organization_membership(organization_id))',
      table_name
    );
    EXECUTE format('REVOKE ALL ON %I FROM PUBLIC, anon, authenticated', table_name);
    EXECUTE format('GRANT SELECT ON %I TO service_role', table_name);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I FROM service_role', table_name);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION create_group_member_discipline_case(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ,
  TIMESTAMPTZ, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_group_member_discipline(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION file_group_member_discipline_appeal(
  UUID, UUID, UUID, UUID, TEXT, JSONB, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_group_member_discipline_appeal(
  UUID, UUID, UUID, UUID, TEXT, TEXT, JSONB, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_group_member_discipline_case(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ,
  TIMESTAMPTZ, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION execute_group_member_discipline(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION file_group_member_discipline_appeal(
  UUID, UUID, UUID, UUID, TEXT, JSONB, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_group_member_discipline_appeal(
  UUID, UUID, UUID, UUID, TEXT, TEXT, JSONB, UUID, TIMESTAMPTZ
) TO service_role;
