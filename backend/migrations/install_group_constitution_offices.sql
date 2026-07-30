-- GT-02A: immutable constitutions, effective-dated offices, and gated activation.

SET search_path = public, extensions;

ALTER TABLE group_members
  ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'group_members_role_check'
      AND conrelid = 'group_members'::REGCLASS
  ) THEN
    ALTER TABLE group_members ADD CONSTRAINT group_members_role_check
      CHECK (role IN ('owner', 'member'));
  END IF;
END $$;
UPDATE group_members AS membership SET role = 'owner'
FROM groups AS group_record
WHERE membership.group_id = group_record.id
  AND membership.user_id = group_record.creator_id;

CREATE OR REPLACE FUNCTION assign_group_creator_role() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM groups
    WHERE id = NEW.group_id AND creator_id = NEW.user_id
  ) THEN NEW.role := 'owner'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS assign_group_creator_role_trigger ON group_members;
CREATE TRIGGER assign_group_creator_role_trigger
  BEFORE INSERT OR UPDATE OF group_id, user_id ON group_members
  FOR EACH ROW EXECUTE FUNCTION assign_group_creator_role();

CREATE TABLE IF NOT EXISTS group_constitutions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL CHECK (version > 0),
  name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 3 AND 160),
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'effective', 'superseded', 'rejected')),
  rules JSONB NOT NULL CHECK (jsonb_typeof(rules) = 'object'),
  adoption_basis TEXT NOT NULL
    CHECK (adoption_basis IN ('initial_owner_adoption', 'approved_proposal', 'legacy_baseline')),
  effective_from TIMESTAMPTZ,
  approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (group_id, version),
  UNIQUE (id, organization_id, group_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_effective_constitution
  ON group_constitutions(group_id) WHERE status = 'effective';
CREATE INDEX IF NOT EXISTS idx_group_constitutions_tenant
  ON group_constitutions(organization_id, group_id, version DESC);

ALTER TABLE groups ADD COLUMN IF NOT EXISTS current_constitution_id UUID;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'groups_current_constitution_fk'
      AND conrelid = 'groups'::REGCLASS
  ) THEN
    ALTER TABLE groups ADD CONSTRAINT groups_current_constitution_fk
      FOREIGN KEY (current_constitution_id) REFERENCES group_constitutions(id)
      ON DELETE RESTRICT;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS group_office_definitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  office_key TEXT NOT NULL CHECK (office_key ~ '^[a-z][a-z0-9_]{1,47}$'),
  display_name TEXT NOT NULL CHECK (length(trim(display_name)) BETWEEN 2 AND 100),
  required_for_activation BOOLEAN NOT NULL DEFAULT FALSE,
  permissions TEXT[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (constitution_id, office_key)
);
CREATE INDEX IF NOT EXISTS idx_group_office_definitions_tenant
  ON group_office_definitions(organization_id, group_id, constitution_id);

CREATE TABLE IF NOT EXISTS group_office_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  office_key TEXT NOT NULL,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  state TEXT NOT NULL DEFAULT 'active'
    CHECK (state IN ('active', 'delegated', 'ended', 'removed')),
  term_starts_at TIMESTAMPTZ NOT NULL,
  term_ends_at TIMESTAMPTZ,
  delegated_from_assignment_id UUID REFERENCES group_office_assignments(id) ON DELETE RESTRICT,
  appointed_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  appointment_basis TEXT NOT NULL
    CHECK (appointment_basis IN ('initial_owner_appointment', 'approved_proposal', 'temporary_delegation', 'legacy_baseline')),
  ended_at TIMESTAMPTZ,
  end_reason_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (constitution_id, office_key)
    REFERENCES group_office_definitions(constitution_id, office_key) ON DELETE RESTRICT,
  CHECK (term_ends_at IS NULL OR term_ends_at > term_starts_at),
  CHECK ((state IN ('ended', 'removed')) = (ended_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_active_office
  ON group_office_assignments(group_id, office_key)
  WHERE state IN ('active', 'delegated');
CREATE INDEX IF NOT EXISTS idx_group_office_history
  ON group_office_assignments(organization_id, group_id, office_key, term_starts_at DESC);

CREATE TABLE IF NOT EXISTS group_governance_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  resource_type TEXT NOT NULL,
  resource_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  correlation_id UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_governance_events_tenant
  ON group_governance_events(organization_id, group_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS group_governance_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  issue_code TEXT NOT NULL CHECK (issue_code IN (
    'LEGACY_CONSTITUTION_BASELINE', 'REQUIRED_OFFICE_MISSING'
  )),
  state TEXT NOT NULL DEFAULT 'open'
    CHECK (state IN ('open', 'resolved', 'accepted_exception')),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  resolution_reason TEXT,
  UNIQUE (group_id, issue_code)
);

-- Existing active groups retain service continuity under an explicit legacy baseline.
INSERT INTO group_constitutions(
  organization_id, group_id, version, name, status, rules, adoption_basis,
  effective_from, approved_by, approved_at, created_by, created_at
)
SELECT
  group_record.organization_id, group_record.id, 1,
  'Legacy baseline constitution', 'effective',
  jsonb_build_object(
    'minimum_members', 1,
    'minimum_offices', jsonb_build_array('chair', 'secretary', 'treasurer'),
    'ordinary_quorum_bps', 5000,
    'ordinary_approval_bps', 5001,
    'special_quorum_bps', 6667,
    'special_approval_bps', 6667,
    'vote_change_allowed', false,
    'source', 'GT-02A_LEGACY_BASELINE'
  ),
  'legacy_baseline', COALESCE(group_record.activated_at, group_record.created_at),
  group_record.creator_id, COALESCE(group_record.activated_at, group_record.created_at),
  group_record.creator_id, group_record.created_at
FROM groups AS group_record
WHERE NOT EXISTS (
  SELECT 1 FROM group_constitutions AS constitution
  WHERE constitution.group_id = group_record.id
)
ON CONFLICT (group_id, version) DO NOTHING;

INSERT INTO group_office_definitions(
  organization_id, group_id, constitution_id, office_key, display_name,
  required_for_activation, permissions
)
SELECT constitution.organization_id, constitution.group_id, constitution.id,
  office.office_key, office.display_name, TRUE, office.permissions
FROM group_constitutions AS constitution
CROSS JOIN (VALUES
  ('chair', 'Chair', ARRAY['groups.governance.manage']::TEXT[]),
  ('secretary', 'Secretary', ARRAY['groups.governance.manage', 'groups.meetings.manage']::TEXT[]),
  ('treasurer', 'Treasurer', ARRAY['groups.treasury.make', 'groups.reports.read']::TEXT[])
) AS office(office_key, display_name, permissions)
ON CONFLICT (constitution_id, office_key) DO NOTHING;

UPDATE groups AS group_record
SET current_constitution_id = constitution.id
FROM group_constitutions AS constitution
WHERE constitution.group_id = group_record.id
  AND constitution.status = 'effective'
  AND group_record.current_constitution_id IS NULL;

INSERT INTO group_governance_reviews(organization_id, group_id, issue_code, evidence)
SELECT organization_id, id, 'LEGACY_CONSTITUTION_BASELINE',
  jsonb_build_object('source', 'GT-02A', 'requires_ratification', TRUE)
FROM groups
ON CONFLICT (group_id, issue_code) DO NOTHING;

INSERT INTO group_governance_reviews(organization_id, group_id, issue_code, evidence)
SELECT organization_id, id, 'REQUIRED_OFFICE_MISSING',
  jsonb_build_object('source', 'GT-02A', 'required_offices', ARRAY['chair', 'secretary', 'treasurer'])
FROM groups
ON CONFLICT (group_id, issue_code) DO NOTHING;

CREATE OR REPLACE FUNCTION protect_group_governance_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_governance_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_TABLE_NAME = 'group_constitutions'
    AND TG_OP = 'UPDATE' AND OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'GROUP_GOVERNANCE_ENGINE_REQUIRED';
END;
$$;

DROP TRIGGER IF EXISTS protect_group_constitutions ON group_constitutions;
CREATE TRIGGER protect_group_constitutions
  BEFORE UPDATE OR DELETE ON group_constitutions
  FOR EACH ROW EXECUTE FUNCTION protect_group_governance_evidence();
DROP TRIGGER IF EXISTS protect_group_office_definitions ON group_office_definitions;
CREATE TRIGGER protect_group_office_definitions
  BEFORE UPDATE OR DELETE ON group_office_definitions
  FOR EACH ROW EXECUTE FUNCTION protect_group_governance_evidence();
DROP TRIGGER IF EXISTS protect_group_office_assignments ON group_office_assignments;
CREATE TRIGGER protect_group_office_assignments
  BEFORE UPDATE OR DELETE ON group_office_assignments
  FOR EACH ROW EXECUTE FUNCTION protect_group_governance_evidence();
DROP TRIGGER IF EXISTS protect_group_governance_events ON group_governance_events;
CREATE TRIGGER protect_group_governance_events
  BEFORE INSERT OR UPDATE OR DELETE ON group_governance_events
  FOR EACH ROW EXECUTE FUNCTION protect_group_governance_evidence();

CREATE OR REPLACE FUNCTION protect_group_constitution_link() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.current_constitution_id IS DISTINCT FROM OLD.current_constitution_id
    AND current_setting('microfams.group_governance_engine', TRUE) <> 'on'
  THEN RAISE EXCEPTION 'GROUP_GOVERNANCE_ENGINE_REQUIRED'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS protect_group_constitution_link_trigger ON groups;
CREATE TRIGGER protect_group_constitution_link_trigger
  BEFORE UPDATE OF current_constitution_id ON groups
  FOR EACH ROW EXECUTE FUNCTION protect_group_constitution_link();

CREATE OR REPLACE FUNCTION assert_group_governance_actor(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM organization_memberships AS tenant_member
    JOIN groups AS group_record
      ON group_record.id = p_group_id
      AND group_record.organization_id = tenant_member.organization_id
    LEFT JOIN group_members AS group_member
      ON group_member.group_id = group_record.id
      AND group_member.user_id = tenant_member.user_id
      AND group_member.status = 'active'
    WHERE tenant_member.organization_id = p_organization_id
      AND tenant_member.user_id = p_actor_id
      AND tenant_member.status = 'active'
      AND (
        tenant_member.role = 'owner'
        OR tenant_member.permissions @> ARRAY['groups.governance.manage']
      )
      AND (
        group_record.creator_id = p_actor_id
        OR group_member.role = 'owner'
        OR tenant_member.role = 'owner'
      )
  ) THEN RAISE EXCEPTION 'GROUP_GOVERNANCE_PERMISSION_DENIED'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION adopt_initial_group_constitution(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_name TEXT,
  p_rules JSONB,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group groups;
  v_constitution_id UUID;
  v_previous_setting TEXT;
BEGIN
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR length(trim(COALESCE(p_name, ''))) NOT BETWEEN 3 AND 160
    OR jsonb_typeof(p_rules) <> 'object'
    OR NOT (p_rules ? 'minimum_members')
    OR NOT (p_rules ? 'ordinary_quorum_bps')
    OR NOT (p_rules ? 'ordinary_approval_bps')
    OR NOT (p_rules ? 'special_quorum_bps')
    OR NOT (p_rules ? 'special_approval_bps')
    OR NOT (p_rules ? 'vote_change_allowed')
  THEN RAISE EXCEPTION 'GROUP_CONSTITUTION_COMMAND_INVALID'; END IF;
  IF (p_rules->>'minimum_members')::INTEGER < 1
    OR (p_rules->>'ordinary_quorum_bps')::INTEGER NOT BETWEEN 1 AND 10000
    OR (p_rules->>'ordinary_approval_bps')::INTEGER NOT BETWEEN 1 AND 10000
    OR (p_rules->>'special_quorum_bps')::INTEGER NOT BETWEEN 1 AND 10000
    OR (p_rules->>'special_approval_bps')::INTEGER NOT BETWEEN 1 AND 10000
    OR jsonb_typeof(p_rules->'vote_change_allowed') <> 'boolean'
  THEN RAISE EXCEPTION 'GROUP_CONSTITUTION_RULE_INVALID'; END IF;
  SELECT resource_id INTO v_constitution_id
  FROM group_governance_events
  WHERE organization_id = p_organization_id
    AND correlation_id = p_correlation_id
    AND event_type = 'CONSTITUTION_ADOPTED';
  IF FOUND THEN RETURN v_constitution_id; END IF;
  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'draft' OR v_group.current_constitution_id IS NOT NULL
    OR EXISTS (SELECT 1 FROM group_constitutions WHERE group_id = p_group_id)
  THEN RAISE EXCEPTION 'GROUP_INITIAL_CONSTITUTION_NOT_ALLOWED'; END IF;
  v_previous_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_constitutions(
    organization_id, group_id, version, name, status, rules, adoption_basis,
    effective_from, approved_by, approved_at, created_by, created_at
  ) VALUES (
    p_organization_id, p_group_id, 1, trim(p_name), 'effective',
    p_rules || jsonb_build_object(
      'minimum_offices', jsonb_build_array('chair', 'secretary', 'treasurer')
    ),
    'initial_owner_adoption', p_occurred_at, p_actor_id, p_occurred_at,
    p_actor_id, p_occurred_at
  ) RETURNING id INTO v_constitution_id;
  INSERT INTO group_office_definitions(
    organization_id, group_id, constitution_id, office_key, display_name,
    required_for_activation, permissions
  ) VALUES
    (p_organization_id, p_group_id, v_constitution_id, 'chair', 'Chair', TRUE,
      ARRAY['groups.governance.manage']),
    (p_organization_id, p_group_id, v_constitution_id, 'secretary', 'Secretary', TRUE,
      ARRAY['groups.governance.manage', 'groups.meetings.manage']),
    (p_organization_id, p_group_id, v_constitution_id, 'treasurer', 'Treasurer', TRUE,
      ARRAY['groups.treasury.make', 'groups.reports.read']);
  UPDATE groups SET current_constitution_id = v_constitution_id
  WHERE id = p_group_id;
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type,
    resource_id, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'CONSTITUTION_ADOPTED',
    'group_constitution', v_constitution_id,
    jsonb_build_object('version', 1, 'basis', 'initial_owner_adoption'),
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config(
    'microfams.group_governance_engine', COALESCE(v_previous_setting, ''), TRUE
  );
  RETURN v_constitution_id;
END;
$$;

CREATE OR REPLACE FUNCTION appoint_initial_group_office(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_office_key TEXT,
  p_member_id UUID,
  p_term_ends_at TIMESTAMPTZ,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group groups;
  v_member group_members;
  v_assignment_id UUID;
  v_previous_setting TEXT;
BEGIN
  IF p_office_key !~ '^[a-z][a-z0-9_]{1,47}$'
    OR p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR (p_term_ends_at IS NOT NULL AND p_term_ends_at <= p_occurred_at)
  THEN RAISE EXCEPTION 'GROUP_OFFICE_COMMAND_INVALID'; END IF;
  SELECT resource_id INTO v_assignment_id FROM group_governance_events
  WHERE organization_id = p_organization_id
    AND correlation_id = p_correlation_id
    AND event_type = 'OFFICE_APPOINTED';
  IF FOUND THEN RETURN v_assignment_id; END IF;
  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'draft' OR v_group.current_constitution_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_INITIAL_OFFICE_NOT_ALLOWED'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_office_definitions
    WHERE constitution_id = v_group.current_constitution_id
      AND office_key = p_office_key
  ) THEN RAISE EXCEPTION 'GROUP_OFFICE_NOT_DEFINED'; END IF;
  SELECT * INTO v_member FROM group_members
  WHERE id = p_member_id AND group_id = p_group_id
    AND organization_id = p_organization_id
    AND status = 'active' AND is_active = TRUE AND payment_status = 'paid';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;
  v_previous_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_office_assignments SET
    state = 'ended', ended_at = p_occurred_at, end_reason_code = 'REPLACED',
    term_ends_at = COALESCE(term_ends_at, p_occurred_at)
  WHERE group_id = p_group_id AND office_key = p_office_key
    AND state IN ('active', 'delegated');
  INSERT INTO group_office_assignments(
    organization_id, group_id, constitution_id, office_key, member_id, user_id,
    state, term_starts_at, term_ends_at, appointed_by, appointment_basis
  ) VALUES (
    p_organization_id, p_group_id, v_group.current_constitution_id,
    p_office_key, v_member.id, v_member.user_id, 'active', p_occurred_at,
    p_term_ends_at, p_actor_id, 'initial_owner_appointment'
  ) RETURNING id INTO v_assignment_id;
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type,
    resource_id, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'OFFICE_APPOINTED',
    'group_office_assignment', v_assignment_id,
    jsonb_build_object('office_key', p_office_key, 'member_id', p_member_id),
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config(
    'microfams.group_governance_engine', COALESCE(v_previous_setting, ''), TRUE
  );
  RETURN v_assignment_id;
END;
$$;

CREATE OR REPLACE FUNCTION activate_group_with_constitution(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_expected_lifecycle_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group groups;
  v_previous_lifecycle_setting TEXT;
  v_previous_governance_setting TEXT;
BEGIN
  IF p_expected_lifecycle_version < 1 OR p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_ACTIVATION_COMMAND_INVALID'; END IF;
  SELECT group_record.* INTO v_group
  FROM group_governance_events AS event
  JOIN groups AS group_record ON group_record.id = event.group_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id
    AND event.event_type = 'GROUP_ACTIVATED';
  IF FOUND THEN RETURN v_group; END IF;
  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'draft'
  THEN RAISE EXCEPTION 'GROUP_ACTIVATION_STATE_INVALID'; END IF;
  IF v_group.lifecycle_version <> p_expected_lifecycle_version
  THEN RAISE EXCEPTION 'GROUP_LIFECYCLE_VERSION_CONFLICT'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_constitutions
    WHERE id = v_group.current_constitution_id
      AND organization_id = p_organization_id
      AND group_id = p_group_id AND status = 'effective'
      AND effective_from <= p_occurred_at
  ) THEN RAISE EXCEPTION 'GROUP_EFFECTIVE_CONSTITUTION_REQUIRED'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_office_definitions AS definition
    WHERE definition.constitution_id = v_group.current_constitution_id
      AND definition.required_for_activation
      AND NOT EXISTS (
        SELECT 1 FROM group_office_assignments AS assignment
        WHERE assignment.constitution_id = definition.constitution_id
          AND assignment.office_key = definition.office_key
          AND assignment.state IN ('active', 'delegated')
          AND assignment.term_starts_at <= p_occurred_at
          AND (assignment.term_ends_at IS NULL OR assignment.term_ends_at > p_occurred_at)
      )
  ) THEN RAISE EXCEPTION 'GROUP_REQUIRED_OFFICES_INCOMPLETE'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_legacy_reviews
    WHERE group_id = p_group_id AND state = 'open'
  ) THEN RAISE EXCEPTION 'GROUP_LEGACY_REVIEW_REQUIRED'; END IF;
  v_previous_lifecycle_setting := current_setting('microfams.group_lifecycle_engine', TRUE);
  v_previous_governance_setting := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_lifecycle_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE groups SET
    lifecycle_state = 'active', lifecycle_version = lifecycle_version + 1,
    lifecycle_reason_code = 'CONSTITUTION_AND_OFFICES_APPROVED',
    is_active = TRUE, activated_at = p_occurred_at, updated_at = p_occurred_at
  WHERE id = p_group_id RETURNING * INTO v_group;
  INSERT INTO group_lifecycle_events(
    organization_id, group_id, actor_id, from_state, to_state, reason_code,
    lifecycle_version, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'draft', 'active',
    'CONSTITUTION_AND_OFFICES_APPROVED', v_group.lifecycle_version,
    p_correlation_id, p_occurred_at
  );
  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type,
    resource_id, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'GROUP_ACTIVATED',
    'group', p_group_id,
    jsonb_build_object(
      'constitution_id', v_group.current_constitution_id,
      'lifecycle_version', v_group.lifecycle_version
    ),
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config(
    'microfams.group_lifecycle_engine', COALESCE(v_previous_lifecycle_setting, ''), TRUE
  );
  PERFORM set_config(
    'microfams.group_governance_engine', COALESCE(v_previous_governance_setting, ''), TRUE
  );
  RETURN v_group;
END;
$$;

-- New groups start private and draft; existing active groups keep their baseline.
CREATE OR REPLACE FUNCTION initialize_group_lifecycle() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.organization_id IS NULL OR NEW.creator_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM organization_memberships AS membership
    JOIN organizations AS organization ON organization.id = membership.organization_id
    WHERE membership.organization_id = NEW.organization_id
      AND membership.user_id = NEW.creator_id
      AND membership.status = 'active' AND organization.status = 'active'
  ) THEN RAISE EXCEPTION 'GROUP_CREATOR_TENANT_MEMBERSHIP_REQUIRED'; END IF;
  NEW.lifecycle_state := 'draft';
  NEW.lifecycle_version := 1;
  NEW.lifecycle_reason_code := 'GROUP_CREATED_DRAFT';
  NEW.activated_at := NULL;
  NEW.suspended_at := NULL;
  NEW.closing_at := NULL;
  NEW.closed_at := NULL;
  NEW.is_active := FALSE;
  NEW.current_constitution_id := NULL;
  RETURN NEW;
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'groups.constitutions.manage', 'groups.offices.manage', 'groups.lifecycle.activate'
  ]) permission
) WHERE role IN ('owner', 'admin');

ALTER TABLE group_constitutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_office_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_office_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_governance_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_governance_reviews ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'group_constitutions', 'group_office_definitions', 'group_office_assignments',
    'group_governance_events', 'group_governance_reviews'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT USING (has_active_organization_membership(organization_id))',
      table_name
    );
    EXECUTE format(
      'REVOKE ALL ON %I FROM PUBLIC, anon, authenticated', table_name
    );
    EXECUTE format('GRANT SELECT ON %I TO service_role', table_name);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I FROM service_role', table_name);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION assert_group_governance_actor(UUID, UUID, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION adopt_initial_group_constitution(
  UUID, UUID, UUID, TEXT, JSONB, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION appoint_initial_group_office(
  UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION activate_group_with_constitution(
  UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION adopt_initial_group_constitution(
  UUID, UUID, UUID, TEXT, JSONB, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION appoint_initial_group_office(
  UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION activate_group_with_constitution(
  UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
