-- GT-01A: tenant-owned group memberships, lifecycle evidence, and quarantine.

SET search_path = public, extensions;

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS lifecycle_state TEXT NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS lifecycle_version INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS lifecycle_reason_code TEXT,
  ADD COLUMN IF NOT EXISTS activated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS closing_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS closed_at TIMESTAMPTZ;

DROP TRIGGER IF EXISTS group_lifecycle_engine_only ON groups;
UPDATE groups SET
  lifecycle_state = CASE WHEN is_active THEN 'active' ELSE 'suspended' END,
  activated_at = CASE WHEN is_active THEN COALESCE(activated_at, created_at) ELSE activated_at END,
  suspended_at = CASE WHEN NOT is_active THEN COALESCE(suspended_at, updated_at) ELSE suspended_at END,
  lifecycle_reason_code = CASE
    WHEN NOT is_active THEN COALESCE(lifecycle_reason_code, 'LEGACY_INACTIVE')
    ELSE lifecycle_reason_code
  END;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'groups_lifecycle_state_check'
      AND conrelid = 'groups'::REGCLASS
  ) THEN
    ALTER TABLE groups ADD CONSTRAINT groups_lifecycle_state_check
      CHECK (lifecycle_state IN ('draft', 'active', 'suspended', 'closing', 'closed'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'groups_lifecycle_version_check'
      AND conrelid = 'groups'::REGCLASS
  ) THEN
    ALTER TABLE groups ADD CONSTRAINT groups_lifecycle_version_check
      CHECK (lifecycle_version > 0);
  END IF;
END $$;

ALTER TABLE group_members
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
UPDATE group_members AS membership
SET organization_id = group_record.organization_id
FROM groups AS group_record
WHERE membership.group_id = group_record.id
  AND membership.organization_id IS NULL;
ALTER TABLE group_members ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_group_members_organization
  ON group_members(organization_id, group_id, status);

ALTER TABLE group_member_action_votes
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
UPDATE group_member_action_votes AS vote
SET organization_id = group_record.organization_id
FROM groups AS group_record
WHERE vote.group_id = group_record.id
  AND vote.organization_id IS NULL;
ALTER TABLE group_member_action_votes ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_group_member_votes_organization
  ON group_member_action_votes(organization_id, group_id, created_at);

CREATE OR REPLACE VIEW public_group_directory
WITH (security_invoker = TRUE) AS
SELECT
  group_record.id,
  group_record.organization_id,
  group_record.name,
  group_record.description,
  group_record.category,
  group_record.state_id,
  state_record.name AS state_name,
  group_record.lga_id,
  lga_record.name AS lga_name,
  group_record.max_members,
  group_record.member_count,
  group_record.entry_fee,
  group_record.created_at
FROM groups AS group_record
LEFT JOIN states AS state_record ON state_record.id = group_record.state_id
LEFT JOIN lgas AS lga_record ON lga_record.id = group_record.lga_id
JOIN organizations AS organization
  ON organization.id = group_record.organization_id
WHERE group_record.lifecycle_state = 'active'
  AND organization.status = 'active';
REVOKE ALL ON public_group_directory FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public_group_directory TO service_role;

CREATE TABLE IF NOT EXISTS group_legacy_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  issue_code TEXT NOT NULL CHECK (issue_code IN (
    'QUARANTINED_TENANT', 'CREATOR_MEMBERSHIP_MISSING',
    'MEMBER_TENANT_MEMBERSHIP_MISSING', 'LIFECYCLE_INCONSISTENT'
  )),
  state TEXT NOT NULL DEFAULT 'open'
    CHECK (state IN ('open', 'resolved', 'accepted_exception')),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(evidence) = 'object'),
  detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  resolution_reason TEXT,
  UNIQUE (group_id, issue_code)
);
CREATE INDEX IF NOT EXISTS idx_group_legacy_reviews_open
  ON group_legacy_reviews(organization_id, state, detected_at)
  WHERE state = 'open';

INSERT INTO group_legacy_reviews(
  organization_id, group_id, issue_code, evidence
)
SELECT group_record.organization_id, group_record.id, 'QUARANTINED_TENANT',
  jsonb_build_object('source', 'GT-01A', 'organization_status', organization.status)
FROM groups AS group_record
JOIN organizations AS organization ON organization.id = group_record.organization_id
WHERE organization.status <> 'active'
ON CONFLICT (group_id, issue_code) DO NOTHING;

INSERT INTO group_legacy_reviews(
  organization_id, group_id, issue_code, evidence
)
SELECT group_record.organization_id, group_record.id, 'CREATOR_MEMBERSHIP_MISSING',
  jsonb_build_object('source', 'GT-01A', 'creator_id', group_record.creator_id)
FROM groups AS group_record
WHERE NOT EXISTS (
  SELECT 1 FROM organization_memberships AS membership
  WHERE membership.organization_id = group_record.organization_id
    AND membership.user_id = group_record.creator_id
    AND membership.status = 'active'
)
ON CONFLICT (group_id, issue_code) DO NOTHING;

INSERT INTO group_legacy_reviews(
  organization_id, group_id, issue_code, evidence
)
SELECT DISTINCT group_record.organization_id, group_record.id,
  'MEMBER_TENANT_MEMBERSHIP_MISSING',
  jsonb_build_object('source', 'GT-01A')
FROM groups AS group_record
JOIN group_members AS group_member ON group_member.group_id = group_record.id
WHERE NOT EXISTS (
  SELECT 1 FROM organization_memberships AS membership
  WHERE membership.organization_id = group_record.organization_id
    AND membership.user_id = group_member.user_id
    AND membership.status = 'active'
)
ON CONFLICT (group_id, issue_code) DO NOTHING;

INSERT INTO group_legacy_reviews(
  organization_id, group_id, issue_code, evidence
)
SELECT organization_id, id, 'LIFECYCLE_INCONSISTENT',
  jsonb_build_object(
    'source', 'GT-01A',
    'lifecycle_state', lifecycle_state,
    'legacy_is_active', is_active
  )
FROM groups
WHERE (lifecycle_state = 'active') <> is_active
ON CONFLICT (group_id, issue_code) DO NOTHING;

UPDATE groups AS group_record SET
  lifecycle_state = 'suspended',
  lifecycle_reason_code = 'LEGACY_REVIEW_REQUIRED',
  suspended_at = COALESCE(group_record.suspended_at, NOW()),
  is_active = FALSE,
  lifecycle_version = group_record.lifecycle_version + 1,
  updated_at = NOW()
WHERE EXISTS (
  SELECT 1 FROM group_legacy_reviews AS review
  WHERE review.group_id = group_record.id AND review.state = 'open'
);

CREATE TABLE IF NOT EXISTS group_lifecycle_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  from_state TEXT,
  to_state TEXT NOT NULL,
  reason_code TEXT NOT NULL
    CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  lifecycle_version INTEGER NOT NULL CHECK (lifecycle_version > 0),
  correlation_id UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  UNIQUE (group_id, lifecycle_version),
  UNIQUE (organization_id, correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_lifecycle_events_tenant
  ON group_lifecycle_events(organization_id, group_id, occurred_at DESC);

DROP TRIGGER IF EXISTS group_lifecycle_event_engine_only ON group_lifecycle_events;
INSERT INTO group_lifecycle_events(
  organization_id, group_id, actor_id, from_state, to_state,
  reason_code, lifecycle_version, correlation_id, occurred_at
)
SELECT organization_id, id, NULL, NULL, lifecycle_state,
  COALESCE(lifecycle_reason_code, 'LEGACY_BASELINE'),
  lifecycle_version, gen_random_uuid(), updated_at
FROM groups
ON CONFLICT (group_id, lifecycle_version) DO NOTHING;

CREATE OR REPLACE FUNCTION enforce_group_tenant_consistency() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_organization_id UUID;
  v_user_id UUID;
BEGIN
  SELECT organization_id INTO v_organization_id
  FROM groups WHERE id = NEW.group_id;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'GROUP_TENANT_NOT_FOUND';
  END IF;
  IF NEW.organization_id IS NULL THEN
    NEW.organization_id := v_organization_id;
  ELSIF NEW.organization_id <> v_organization_id THEN
    RAISE EXCEPTION 'GROUP_TENANT_MISMATCH';
  END IF;
  IF TG_TABLE_NAME = 'group_members' THEN
    v_user_id := NEW.user_id;
    IF NOT EXISTS (
      SELECT 1 FROM organization_memberships
      WHERE organization_id = v_organization_id
        AND user_id = v_user_id AND status = 'active'
    ) THEN RAISE EXCEPTION 'GROUP_MEMBER_TENANT_MEMBERSHIP_REQUIRED'; END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_group_member_tenant ON group_members;
CREATE TRIGGER enforce_group_member_tenant
  BEFORE INSERT OR UPDATE OF organization_id, group_id, user_id ON group_members
  FOR EACH ROW EXECUTE FUNCTION enforce_group_tenant_consistency();
DROP TRIGGER IF EXISTS enforce_group_vote_tenant ON group_member_action_votes;
CREATE TRIGGER enforce_group_vote_tenant
  BEFORE INSERT OR UPDATE OF organization_id, group_id
  ON group_member_action_votes
  FOR EACH ROW EXECUTE FUNCTION enforce_group_tenant_consistency();

CREATE OR REPLACE FUNCTION protect_group_lifecycle() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF (
    NEW.lifecycle_state, NEW.lifecycle_version, NEW.lifecycle_reason_code,
    NEW.activated_at, NEW.suspended_at, NEW.closing_at, NEW.closed_at,
    NEW.is_active
  ) IS DISTINCT FROM (
    OLD.lifecycle_state, OLD.lifecycle_version, OLD.lifecycle_reason_code,
    OLD.activated_at, OLD.suspended_at, OLD.closing_at, OLD.closed_at,
    OLD.is_active
  ) AND current_setting('microfams.group_lifecycle_engine', TRUE) <> 'on'
  THEN RAISE EXCEPTION 'GROUP_LIFECYCLE_ENGINE_REQUIRED'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS group_lifecycle_engine_only ON groups;
CREATE TRIGGER group_lifecycle_engine_only
  BEFORE UPDATE ON groups
  FOR EACH ROW EXECUTE FUNCTION protect_group_lifecycle();

CREATE OR REPLACE FUNCTION initialize_group_lifecycle() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.organization_id IS NULL OR NEW.creator_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM organization_memberships AS membership
    JOIN organizations AS organization
      ON organization.id = membership.organization_id
    WHERE membership.organization_id = NEW.organization_id
      AND membership.user_id = NEW.creator_id
      AND membership.status = 'active'
      AND organization.status = 'active'
  ) THEN
    RAISE EXCEPTION 'GROUP_CREATOR_TENANT_MEMBERSHIP_REQUIRED';
  END IF;

  NEW.lifecycle_state := 'active';
  NEW.lifecycle_version := 1;
  NEW.lifecycle_reason_code := 'GROUP_CREATED';
  NEW.activated_at := COALESCE(NEW.activated_at, NEW.created_at, NOW());
  NEW.suspended_at := NULL;
  NEW.closing_at := NULL;
  NEW.closed_at := NULL;
  NEW.is_active := TRUE;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS initialize_group_lifecycle_trigger ON groups;
CREATE TRIGGER initialize_group_lifecycle_trigger
  BEFORE INSERT ON groups
  FOR EACH ROW EXECUTE FUNCTION initialize_group_lifecycle();

CREATE OR REPLACE FUNCTION protect_group_lifecycle_event() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_lifecycle_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'GROUP_LIFECYCLE_ENGINE_REQUIRED';
END;
$$;
DROP TRIGGER IF EXISTS group_lifecycle_event_engine_only ON group_lifecycle_events;
CREATE TRIGGER group_lifecycle_event_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON group_lifecycle_events
  FOR EACH ROW EXECUTE FUNCTION protect_group_lifecycle_event();

CREATE OR REPLACE FUNCTION record_initial_group_lifecycle() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_previous_setting TEXT;
BEGIN
  v_previous_setting := current_setting('microfams.group_lifecycle_engine', TRUE);
  PERFORM set_config('microfams.group_lifecycle_engine', 'on', TRUE);
  INSERT INTO group_lifecycle_events(
    organization_id, group_id, actor_id, from_state, to_state,
    reason_code, lifecycle_version, correlation_id, occurred_at
  ) VALUES (
    NEW.organization_id, NEW.id, NEW.creator_id, NULL, NEW.lifecycle_state,
    'GROUP_CREATED', NEW.lifecycle_version, gen_random_uuid(), NEW.created_at
  );
  PERFORM set_config(
    'microfams.group_lifecycle_engine', COALESCE(v_previous_setting, ''), TRUE
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS record_initial_group_lifecycle_trigger ON groups;
CREATE TRIGGER record_initial_group_lifecycle_trigger
  AFTER INSERT ON groups
  FOR EACH ROW EXECUTE FUNCTION record_initial_group_lifecycle();

CREATE OR REPLACE FUNCTION transition_group_lifecycle(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_target_state TEXT,
  p_reason_code TEXT,
  p_expected_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS groups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group groups;
  v_from_state TEXT;
  v_previous_setting TEXT;
BEGIN
  IF p_target_state NOT IN ('active', 'suspended', 'closing', 'closed')
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    OR p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_LIFECYCLE_COMMAND_INVALID'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id
      AND status = 'active'
      AND (
        role IN ('owner', 'admin')
        OR permissions @> ARRAY['groups.lifecycle.manage']
      )
  ) THEN RAISE EXCEPTION 'GROUP_LIFECYCLE_PERMISSION_DENIED'; END IF;
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_version <> p_expected_version THEN
    RAISE EXCEPTION 'GROUP_LIFECYCLE_VERSION_CONFLICT';
  END IF;
  IF v_group.lifecycle_state = p_target_state THEN RETURN v_group; END IF;
  IF NOT (
    (v_group.lifecycle_state = 'active' AND p_target_state IN ('suspended', 'closing'))
    OR (v_group.lifecycle_state = 'suspended' AND p_target_state IN ('active', 'closing'))
    OR (v_group.lifecycle_state = 'closing' AND p_target_state = 'closed')
  ) THEN RAISE EXCEPTION 'GROUP_LIFECYCLE_TRANSITION_INVALID'; END IF;
  IF p_target_state = 'active' AND EXISTS (
    SELECT 1 FROM group_legacy_reviews
    WHERE group_id = p_group_id AND state = 'open'
  ) THEN RAISE EXCEPTION 'GROUP_LEGACY_REVIEW_REQUIRED'; END IF;
  v_from_state := v_group.lifecycle_state;
  v_previous_setting := current_setting('microfams.group_lifecycle_engine', TRUE);
  PERFORM set_config('microfams.group_lifecycle_engine', 'on', TRUE);
  UPDATE groups SET
    lifecycle_state = p_target_state,
    lifecycle_version = lifecycle_version + 1,
    lifecycle_reason_code = p_reason_code,
    is_active = p_target_state = 'active',
    activated_at = CASE WHEN p_target_state = 'active' THEN p_occurred_at ELSE activated_at END,
    suspended_at = CASE WHEN p_target_state = 'suspended' THEN p_occurred_at ELSE suspended_at END,
    closing_at = CASE WHEN p_target_state = 'closing' THEN p_occurred_at ELSE closing_at END,
    closed_at = CASE WHEN p_target_state = 'closed' THEN p_occurred_at ELSE closed_at END,
    updated_at = p_occurred_at
  WHERE id = p_group_id
  RETURNING * INTO v_group;
  INSERT INTO group_lifecycle_events(
    organization_id, group_id, actor_id, from_state, to_state,
    reason_code, lifecycle_version, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id,
    v_from_state,
    p_target_state, p_reason_code, v_group.lifecycle_version,
    p_correlation_id, p_occurred_at
  );
  PERFORM set_config(
    'microfams.group_lifecycle_engine', COALESCE(v_previous_setting, ''), TRUE
  );
  RETURN v_group;
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'groups.read', 'groups.create', 'groups.membership.manage',
    'groups.lifecycle.manage', 'groups.governance.manage',
    'groups.contributions.manage', 'groups.treasury.make',
    'groups.treasury.approve', 'groups.projects.manage',
    'groups.meetings.manage', 'groups.documents.manage',
    'groups.assets.manage', 'groups.audit.read'
  ]) permission
) WHERE role = 'owner';
UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'groups.read', 'groups.create', 'groups.membership.manage',
    'groups.lifecycle.manage', 'groups.governance.manage',
    'groups.contributions.manage', 'groups.treasury.make',
    'groups.projects.manage', 'groups.meetings.manage',
    'groups.documents.manage', 'groups.assets.manage'
  ]) permission
) WHERE role = 'admin';
UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY['groups.read']) permission
) WHERE role IN ('finance_manager', 'program_manager', 'farm_manager', 'auditor', 'member', 'viewer');

ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Tenant members read group memberships" ON group_members;
DROP POLICY IF EXISTS group_members_tenant_read ON group_members;
CREATE POLICY group_members_tenant_read ON group_members FOR SELECT
  USING (has_active_organization_membership(organization_id));

ALTER TABLE group_member_action_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS group_votes_tenant_read ON group_member_action_votes;
CREATE POLICY group_votes_tenant_read ON group_member_action_votes FOR SELECT
  USING (has_active_organization_membership(organization_id));

ALTER TABLE group_lifecycle_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS group_lifecycle_events_tenant_read ON group_lifecycle_events;
CREATE POLICY group_lifecycle_events_tenant_read ON group_lifecycle_events FOR SELECT
  USING (has_active_organization_membership(organization_id));
ALTER TABLE group_legacy_reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS group_legacy_reviews_tenant_read ON group_legacy_reviews;
CREATE POLICY group_legacy_reviews_tenant_read ON group_legacy_reviews FOR SELECT
  USING (has_active_organization_membership(organization_id));

REVOKE ALL ON group_lifecycle_events, group_legacy_reviews
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON group_lifecycle_events, group_legacy_reviews TO service_role;
REVOKE INSERT, UPDATE, DELETE ON group_lifecycle_events, group_legacy_reviews
  FROM service_role;
REVOKE ALL ON FUNCTION transition_group_lifecycle(
  UUID, UUID, UUID, TEXT, TEXT, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION transition_group_lifecycle(
  UUID, UUID, UUID, TEXT, TEXT, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
