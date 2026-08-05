-- GT-02D: proposal-backed office decisions, bounded delegation, and vacancy servicing.

SET search_path = public, extensions;

ALTER TABLE group_office_definitions
  ADD COLUMN IF NOT EXISTS term_required BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS max_term_days INTEGER,
  ADD COLUMN IF NOT EXISTS delegation_allowed BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS max_delegation_days INTEGER NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS incompatible_office_keys TEXT[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'group_office_definition_term_rules_check'
      AND conrelid = 'group_office_definitions'::REGCLASS
  ) THEN
    ALTER TABLE group_office_definitions
      ADD CONSTRAINT group_office_definition_term_rules_check CHECK (
        (max_term_days IS NULL OR max_term_days BETWEEN 1 AND 3650)
        AND max_delegation_days BETWEEN 1 AND 365
        AND NOT (office_key = ANY(incompatible_office_keys))
      );
  END IF;
END $$;

-- The GT-02A guard used a cross-table OLD.status reference. Keep the draft-only
-- constitution exception without evaluating constitution fields for office rows.
CREATE OR REPLACE FUNCTION protect_group_governance_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_governance_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_TABLE_NAME = 'group_constitutions' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'draft' THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'GROUP_GOVERNANCE_ENGINE_REQUIRED';
END;
$$;

CREATE OR REPLACE FUNCTION execute_group_office_proposal(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_proposal_id UUID,
  p_expected_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_proposals
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_proposal group_proposals;
  v_group groups;
  v_definition group_office_definitions;
  v_member group_members;
  v_assignment group_office_assignments;
  v_resource_id UUID;
  v_office_key TEXT;
  v_member_id UUID;
  v_assignment_id UUID;
  v_term_ends_at TIMESTAMPTZ;
  v_reason_code TEXT;
  v_previous_proposal_setting TEXT;
  v_previous_governance_setting TEXT;
BEGIN
  SELECT proposal.* INTO v_proposal
  FROM group_proposal_events AS event
  JOIN group_proposals AS proposal ON proposal.id = event.proposal_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id
    AND event.event_type = 'OFFICE_DECISION_EXECUTED';
  IF FOUND THEN RETURN v_proposal; END IF;
  IF p_expected_version < 1 OR p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_OFFICE_EXECUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'active'
  THEN RAISE EXCEPTION 'GROUP_OFFICE_ACTIVE_GROUP_REQUIRED'; END IF;

  SELECT * INTO v_proposal FROM group_proposals
  WHERE id = p_proposal_id
    AND organization_id = p_organization_id
    AND group_id = p_group_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND'; END IF;
  IF v_proposal.state <> 'approved' OR v_proposal.state_version <> p_expected_version
  THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VERSION_CONFLICT'; END IF;
  IF v_proposal.proposal_type NOT IN ('office_appointment', 'office_removal')
  THEN RAISE EXCEPTION 'GROUP_OFFICE_PROPOSAL_TYPE_INVALID'; END IF;
  IF v_proposal.constitution_id <> v_group.current_constitution_id
  THEN RAISE EXCEPTION 'GROUP_OFFICE_CONSTITUTION_CHANGED'; END IF;

  v_previous_proposal_setting := current_setting('microfams.group_proposal_engine', TRUE);
  v_previous_governance_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_proposal_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_proposals SET state = 'executing', state_version = state_version + 1,
    updated_at = p_occurred_at WHERE id = v_proposal.id;

  IF v_proposal.proposal_type = 'office_appointment' THEN
    v_office_key := v_proposal.execution_payload->>'office_key';
    BEGIN
      v_member_id := (v_proposal.execution_payload->>'member_id')::UUID;
      v_term_ends_at := NULLIF(v_proposal.execution_payload->>'term_ends_at', '')::TIMESTAMPTZ;
    EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
      RAISE EXCEPTION 'GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID';
    END;
    IF v_office_key !~ '^[a-z][a-z0-9_]{1,47}$' OR v_member_id IS NULL
    THEN RAISE EXCEPTION 'GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID'; END IF;
    SELECT * INTO v_definition FROM group_office_definitions
    WHERE organization_id = p_organization_id AND group_id = p_group_id
      AND constitution_id = v_proposal.constitution_id
      AND office_key = v_office_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_OFFICE_NOT_DEFINED'; END IF;
    IF v_definition.term_required AND v_term_ends_at IS NULL
    THEN RAISE EXCEPTION 'GROUP_OFFICE_TERM_REQUIRED'; END IF;
    IF v_term_ends_at IS NOT NULL AND (
      v_term_ends_at <= p_occurred_at OR (
        v_definition.max_term_days IS NOT NULL
        AND v_term_ends_at > p_occurred_at + make_interval(days => v_definition.max_term_days)
      )
    ) THEN RAISE EXCEPTION 'GROUP_OFFICE_TERM_INVALID'; END IF;
    SELECT * INTO v_member FROM group_members
    WHERE id = v_member_id AND organization_id = p_organization_id
      AND group_id = p_group_id AND status = 'active'
      AND is_active = TRUE AND payment_status = 'paid';
    IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;
    IF NOT (v_member.user_id = ANY(v_proposal.conflict_user_ids))
    THEN RAISE EXCEPTION 'GROUP_OFFICE_BENEFICIARY_CONFLICT_NOT_EXCLUDED'; END IF;
    IF EXISTS (
      SELECT 1 FROM group_office_assignments AS held
      WHERE held.organization_id = p_organization_id AND held.group_id = p_group_id
        AND held.user_id = v_member.user_id AND held.state IN ('active', 'delegated')
        AND (
          held.office_key = ANY(v_definition.incompatible_office_keys)
          OR v_office_key = ANY(COALESCE((
            SELECT incompatible_office_keys FROM group_office_definitions
            WHERE constitution_id = v_proposal.constitution_id
              AND office_key = held.office_key
          ), '{}'))
        )
    ) THEN RAISE EXCEPTION 'GROUP_OFFICE_SEPARATION_CONFLICT'; END IF;
    UPDATE group_office_assignments SET state = 'ended', ended_at = p_occurred_at,
      end_reason_code = 'REPLACED_BY_APPROVED_APPOINTMENT'
    WHERE organization_id = p_organization_id AND group_id = p_group_id
      AND office_key = v_office_key AND state IN ('active', 'delegated');
    INSERT INTO group_office_assignments(
      organization_id, group_id, constitution_id, office_key, member_id, user_id,
      state, term_starts_at, term_ends_at, appointed_by, appointment_basis
    ) VALUES (
      p_organization_id, p_group_id, v_proposal.constitution_id, v_office_key,
      v_member.id, v_member.user_id, 'active', p_occurred_at, v_term_ends_at,
      p_actor_id, 'approved_proposal'
    ) RETURNING id INTO v_resource_id;
  ELSE
    BEGIN
      v_assignment_id := (v_proposal.execution_payload->>'assignment_id')::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID';
    END;
    v_reason_code := v_proposal.execution_payload->>'reason_code';
    IF v_assignment_id IS NULL OR v_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    THEN RAISE EXCEPTION 'GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID'; END IF;
    SELECT * INTO v_assignment FROM group_office_assignments
    WHERE id = v_assignment_id AND organization_id = p_organization_id
      AND group_id = p_group_id AND state IN ('active', 'delegated')
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_OFFICE_ASSIGNMENT_NOT_ACTIVE'; END IF;
    IF NOT (v_assignment.user_id = ANY(v_proposal.conflict_user_ids))
    THEN RAISE EXCEPTION 'GROUP_OFFICE_TARGET_CONFLICT_NOT_EXCLUDED'; END IF;
    UPDATE group_office_assignments SET state = 'removed', ended_at = p_occurred_at,
      end_reason_code = v_reason_code WHERE id = v_assignment.id;
    v_office_key := v_assignment.office_key;
    v_resource_id := v_assignment.id;
  END IF;

  UPDATE group_proposals SET state = 'executed', state_version = state_version + 1,
    result = COALESCE(result, '{}'::JSONB) || jsonb_build_object(
      'executed_resource_type', 'group_office_assignment',
      'executed_resource_id', v_resource_id,
      'office_key', v_office_key,
      'executed_at', p_occurred_at
    ), updated_at = p_occurred_at
  WHERE id = v_proposal.id RETURNING * INTO v_proposal;
  INSERT INTO group_proposal_events(
    organization_id, group_id, proposal_id, actor_id, event_type, from_state,
    to_state, resource_id, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_proposal.id, p_actor_id,
    'OFFICE_DECISION_EXECUTED', 'approved', 'executed', v_resource_id,
    p_correlation_id, jsonb_build_object('office_key', v_office_key), p_occurred_at
  );
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id,
    CASE WHEN v_proposal.proposal_type = 'office_appointment'
      THEN 'OFFICE_APPOINTED' ELSE 'OFFICE_REMOVED' END,
    'group_office_assignment', v_resource_id,
    jsonb_build_object('office_key', v_office_key, 'proposal_id', v_proposal.id),
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_proposal_engine', COALESCE(v_previous_proposal_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance_setting, ''), TRUE);
  RETURN v_proposal;
END;
$$;

CREATE OR REPLACE FUNCTION delegate_group_office(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID, p_office_key TEXT,
  p_assignment_id UUID, p_delegate_member_id UUID, p_delegation_ends_at TIMESTAMPTZ,
  p_correlation_id UUID, p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_source group_office_assignments;
  v_definition group_office_definitions;
  v_delegate group_members;
  v_delegation_id UUID;
  v_previous_setting TEXT;
BEGIN
  SELECT resource_id INTO v_delegation_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'OFFICE_DELEGATED';
  IF FOUND THEN RETURN v_delegation_id; END IF;
  IF p_office_key !~ '^[a-z][a-z0-9_]{1,47}$' OR p_correlation_id IS NULL
    OR p_delegation_ends_at <= p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_OFFICE_DELEGATION_COMMAND_INVALID'; END IF;
  SELECT * INTO v_source FROM group_office_assignments
  WHERE id = p_assignment_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND office_key = p_office_key AND state = 'active'
    AND term_starts_at <= p_occurred_at
    AND (term_ends_at IS NULL OR term_ends_at > p_occurred_at)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_OFFICE_ASSIGNMENT_NOT_ACTIVE'; END IF;
  IF v_source.user_id <> p_actor_id THEN
    PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  END IF;
  SELECT * INTO v_definition FROM group_office_definitions
  WHERE constitution_id = v_source.constitution_id AND office_key = p_office_key;
  IF NOT v_definition.delegation_allowed
  THEN RAISE EXCEPTION 'GROUP_OFFICE_DELEGATION_NOT_ALLOWED'; END IF;
  IF p_delegation_ends_at > p_occurred_at + make_interval(days => v_definition.max_delegation_days)
    OR (v_source.term_ends_at IS NOT NULL AND p_delegation_ends_at > v_source.term_ends_at)
  THEN RAISE EXCEPTION 'GROUP_OFFICE_DELEGATION_WINDOW_INVALID'; END IF;
  SELECT * INTO v_delegate FROM group_members
  WHERE id = p_delegate_member_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND status = 'active' AND is_active = TRUE
    AND payment_status = 'paid';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;
  IF v_delegate.user_id = v_source.user_id
  THEN RAISE EXCEPTION 'GROUP_OFFICE_SELF_DELEGATION_INVALID'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_office_assignments AS held
    WHERE held.organization_id = p_organization_id AND held.group_id = p_group_id
      AND held.user_id = v_delegate.user_id AND held.state IN ('active', 'delegated')
      AND (
        held.office_key = ANY(v_definition.incompatible_office_keys)
        OR p_office_key = ANY(COALESCE((
          SELECT incompatible_office_keys FROM group_office_definitions
          WHERE constitution_id = v_source.constitution_id AND office_key = held.office_key
        ), '{}'))
      )
  ) THEN RAISE EXCEPTION 'GROUP_OFFICE_SEPARATION_CONFLICT'; END IF;
  v_previous_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_office_assignments SET state = 'ended', ended_at = p_occurred_at,
    end_reason_code = 'TEMPORARY_DELEGATION' WHERE id = v_source.id;
  INSERT INTO group_office_assignments(
    organization_id, group_id, constitution_id, office_key, member_id, user_id,
    state, term_starts_at, term_ends_at, delegated_from_assignment_id,
    appointed_by, appointment_basis
  ) VALUES (
    p_organization_id, p_group_id, v_source.constitution_id, p_office_key,
    v_delegate.id, v_delegate.user_id, 'delegated', p_occurred_at,
    p_delegation_ends_at, v_source.id, p_actor_id, 'temporary_delegation'
  ) RETURNING id INTO v_delegation_id;
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'OFFICE_DELEGATED',
    'group_office_assignment', v_delegation_id,
    jsonb_build_object('office_key', p_office_key, 'source_assignment_id', v_source.id,
      'delegate_member_id', v_delegate.id, 'delegation_ends_at', p_delegation_ends_at),
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_delegation_id;
END;
$$;

CREATE OR REPLACE FUNCTION end_group_office_delegation(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID, p_office_key TEXT,
  p_delegation_id UUID, p_reason_code TEXT, p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_delegation group_office_assignments;
  v_source group_office_assignments;
  v_restored_id UUID;
  v_event_resource UUID;
  v_previous_setting TEXT;
BEGIN
  SELECT resource_id INTO v_event_resource FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'OFFICE_DELEGATION_ENDED';
  IF FOUND THEN RETURN v_event_resource; END IF;
  IF p_office_key !~ '^[a-z][a-z0-9_]{1,47}$'
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_OFFICE_DELEGATION_END_COMMAND_INVALID'; END IF;
  SELECT * INTO v_delegation FROM group_office_assignments
  WHERE id = p_delegation_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND office_key = p_office_key AND state = 'delegated'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_OFFICE_DELEGATION_NOT_ACTIVE'; END IF;
  SELECT * INTO v_source FROM group_office_assignments
  WHERE id = v_delegation.delegated_from_assignment_id;
  IF p_actor_id NOT IN (v_source.user_id, v_delegation.user_id) THEN
    PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  END IF;
  v_previous_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_office_assignments SET state = 'ended', ended_at = p_occurred_at,
    end_reason_code = p_reason_code WHERE id = v_delegation.id;
  IF (v_source.term_ends_at IS NULL OR v_source.term_ends_at > p_occurred_at)
    AND EXISTS (
      SELECT 1 FROM group_members WHERE id = v_source.member_id
        AND organization_id = p_organization_id AND group_id = p_group_id
        AND status = 'active' AND is_active = TRUE AND payment_status = 'paid'
    ) THEN
    INSERT INTO group_office_assignments(
      organization_id, group_id, constitution_id, office_key, member_id, user_id,
      state, term_starts_at, term_ends_at, delegated_from_assignment_id,
      appointed_by, appointment_basis
    ) VALUES (
      p_organization_id, p_group_id, v_source.constitution_id, p_office_key,
      v_source.member_id, v_source.user_id, 'active', p_occurred_at,
      v_source.term_ends_at, v_source.id, p_actor_id, 'temporary_delegation'
    ) RETURNING id INTO v_restored_id;
  END IF;
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'OFFICE_DELEGATION_ENDED',
    'group_office_assignment', v_delegation.id,
    jsonb_build_object('office_key', p_office_key, 'reason_code', p_reason_code,
      'restored_assignment_id', v_restored_id), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_delegation.id;
END;
$$;

CREATE OR REPLACE FUNCTION service_expired_group_offices(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID,
  p_correlation_id UUID, p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_assignment group_office_assignments;
  v_source group_office_assignments;
  v_count INTEGER := 0;
  v_restored_count INTEGER := 0;
  v_previous_setting TEXT;
  v_existing JSONB;
BEGIN
  SELECT evidence INTO v_existing FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'OFFICE_TERMS_SERVICED';
  IF FOUND THEN RETURN v_existing; END IF;
  IF p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_OFFICE_SERVICE_COMMAND_INVALID'; END IF;
  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  v_previous_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  FOR v_assignment IN
    SELECT * FROM group_office_assignments
    WHERE organization_id = p_organization_id AND group_id = p_group_id
      AND state IN ('active', 'delegated') AND term_ends_at <= p_occurred_at
    ORDER BY term_ends_at, id FOR UPDATE
  LOOP
    UPDATE group_office_assignments SET state = 'ended', ended_at = p_occurred_at,
      end_reason_code = CASE WHEN v_assignment.state = 'delegated'
        THEN 'DELEGATION_EXPIRED' ELSE 'TERM_EXPIRED' END
    WHERE id = v_assignment.id;
    v_count := v_count + 1;
    IF v_assignment.state = 'delegated' THEN
      SELECT * INTO v_source FROM group_office_assignments
      WHERE id = v_assignment.delegated_from_assignment_id;
      IF (v_source.term_ends_at IS NULL OR v_source.term_ends_at > p_occurred_at)
        AND EXISTS (
          SELECT 1 FROM group_members WHERE id = v_source.member_id
            AND organization_id = p_organization_id AND group_id = p_group_id
            AND status = 'active' AND is_active = TRUE AND payment_status = 'paid'
        ) THEN
        INSERT INTO group_office_assignments(
          organization_id, group_id, constitution_id, office_key, member_id, user_id,
          state, term_starts_at, term_ends_at, delegated_from_assignment_id,
          appointed_by, appointment_basis
        ) VALUES (
          p_organization_id, p_group_id, v_source.constitution_id,
          v_assignment.office_key, v_source.member_id, v_source.user_id, 'active',
          p_occurred_at, v_source.term_ends_at, v_source.id, p_actor_id,
          'temporary_delegation'
        );
        v_restored_count := v_restored_count + 1;
      END IF;
    END IF;
  END LOOP;
  v_existing := jsonb_build_object('serviced_count', v_count,
    'restored_count', v_restored_count, 'serviced_at', p_occurred_at);
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'OFFICE_TERMS_SERVICED',
    'group', p_group_id, v_existing, p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_existing;
END;
$$;

REVOKE ALL ON FUNCTION execute_group_office_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION delegate_group_office(UUID,UUID,UUID,TEXT,UUID,UUID,TIMESTAMPTZ,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION end_group_office_delegation(UUID,UUID,UUID,TEXT,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION service_expired_group_offices(UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION execute_group_office_proposal(UUID,UUID,UUID,UUID,INTEGER,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION delegate_group_office(UUID,UUID,UUID,TEXT,UUID,UUID,TIMESTAMPTZ,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION end_group_office_delegation(UUID,UUID,UUID,TEXT,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
