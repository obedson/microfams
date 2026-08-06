-- GT-09: Committees and meetings with effective-dated membership and immutable approved minutes.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS group_committees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id),
  committee_key TEXT NOT NULL CHECK (committee_key ~ '^[a-z][a-z0-9_]{1,47}$'),
  display_name TEXT NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 200),
  mandate TEXT NOT NULL CHECK (char_length(mandate) BETWEEN 1 AND 5000),
  delegated_permissions TEXT[] NOT NULL DEFAULT '{}',
  spending_ceiling_minor_units BIGINT CHECK (spending_ceiling_minor_units >= 0),
  spending_ceiling_currency TEXT CHECK (spending_ceiling_currency ~ '^[A-Z]{3}$'),
  reporting_duties TEXT CHECK (char_length(reporting_duties) <= 2000),
  term_starts_at TIMESTAMPTZ NOT NULL,
  term_ends_at TIMESTAMPTZ,
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'dissolved')),
  dissolved_at TIMESTAMPTZ,
  dissolution_reason_code TEXT CHECK (dissolution_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (term_ends_at IS NULL OR term_ends_at > term_starts_at),
  CHECK ((state = 'dissolved') = (dissolved_at IS NOT NULL)),
  CHECK ((spending_ceiling_minor_units IS NULL) = (spending_ceiling_currency IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_committee_active_key
  ON group_committees(organization_id, group_id, committee_key) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS idx_group_committees_tenant
  ON group_committees(organization_id, group_id, state);

CREATE TABLE IF NOT EXISTS group_committee_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  committee_id UUID NOT NULL REFERENCES group_committees(id),
  member_id UUID NOT NULL REFERENCES group_members(id),
  user_id UUID NOT NULL REFERENCES users(id),
  committee_role TEXT NOT NULL CHECK (committee_role IN ('member', 'chair')),
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ,
  end_reason_code TEXT CHECK (end_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  appointed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (ends_at IS NULL OR ends_at > starts_at),
  CHECK ((ends_at IS NULL) = (end_reason_code IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_committee_member_current
  ON group_committee_members(committee_id, member_id) WHERE ends_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_committee_single_chair
  ON group_committee_members(committee_id) WHERE ends_at IS NULL AND committee_role = 'chair';
CREATE INDEX IF NOT EXISTS idx_group_committee_members_tenant
  ON group_committee_members(organization_id, group_id, committee_id);

CREATE TABLE IF NOT EXISTS group_meetings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  committee_id UUID REFERENCES group_committees(id),
  meeting_type TEXT NOT NULL
    CHECK (meeting_type IN ('general', 'committee', 'special', 'emergency')),
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 500),
  agenda JSONB NOT NULL DEFAULT '[]'::JSONB CHECK (jsonb_typeof(agenda) = 'array'),
  scheduled_at TIMESTAMPTZ NOT NULL,
  notice_issued_at TIMESTAMPTZ NOT NULL,
  required_notice_hours INTEGER NOT NULL CHECK (required_notice_hours BETWEEN 0 AND 8760),
  emergency_reason TEXT CHECK (char_length(emergency_reason) BETWEEN 1 AND 2000),
  location TEXT CHECK (char_length(location) <= 500),
  quorum_numerator INTEGER NOT NULL CHECK (quorum_numerator > 0),
  quorum_denominator INTEGER NOT NULL CHECK (quorum_denominator > 0),
  eligible_attendee_count INTEGER NOT NULL CHECK (eligible_attendee_count >= 0),
  state TEXT NOT NULL DEFAULT 'scheduled'
    CHECK (state IN ('scheduled', 'held', 'cancelled')),
  quorum_met BOOLEAN,
  held_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  cancellation_reason_code TEXT CHECK (cancellation_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version > 0),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (quorum_numerator <= quorum_denominator),
  CHECK ((state = 'cancelled') = (cancelled_at IS NOT NULL)),
  CHECK ((state = 'cancelled') = (cancellation_reason_code IS NOT NULL)),
  CHECK ((state = 'held') = (held_at IS NOT NULL)),
  CHECK ((state = 'held') = (quorum_met IS NOT NULL)),
  CHECK ((meeting_type = 'emergency') = (emergency_reason IS NOT NULL)),
  CHECK (meeting_type <> 'committee' OR committee_id IS NOT NULL),
  CHECK (meeting_type = 'committee' OR committee_id IS NULL)
);
CREATE INDEX IF NOT EXISTS idx_group_meetings_tenant
  ON group_meetings(organization_id, group_id, state, scheduled_at DESC);
CREATE INDEX IF NOT EXISTS idx_group_meetings_committee
  ON group_meetings(committee_id) WHERE committee_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS group_meeting_attendance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  meeting_id UUID NOT NULL REFERENCES group_meetings(id),
  member_id UUID NOT NULL REFERENCES group_members(id),
  user_id UUID NOT NULL REFERENCES users(id),
  attendance_status TEXT NOT NULL
    CHECK (attendance_status IN ('present', 'absent', 'apology', 'proxy')),
  recorded_by UUID REFERENCES users(id) ON DELETE SET NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (meeting_id, member_id)
);
CREATE INDEX IF NOT EXISTS idx_group_meeting_attendance_tenant
  ON group_meeting_attendance(organization_id, meeting_id);

CREATE TABLE IF NOT EXISTS group_meeting_minutes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  meeting_id UUID NOT NULL REFERENCES group_meetings(id),
  version INTEGER NOT NULL CHECK (version > 0),
  minutes_kind TEXT NOT NULL DEFAULT 'minutes'
    CHECK (minutes_kind IN ('minutes', 'addendum')),
  corrects_minutes_id UUID REFERENCES group_meeting_minutes(id),
  content TEXT NOT NULL CHECK (char_length(content) BETWEEN 1 AND 50000),
  resolutions JSONB NOT NULL DEFAULT '[]'::JSONB
    CHECK (jsonb_typeof(resolutions) = 'array'),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'approved')),
  approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_at TIMESTAMPTZ,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (meeting_id, version),
  CHECK ((state = 'approved') = (approved_at IS NOT NULL)),
  CHECK ((state = 'approved') = (approved_by IS NOT NULL)),
  CHECK ((minutes_kind = 'addendum') = (corrects_minutes_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_meeting_minutes_single_draft
  ON group_meeting_minutes(meeting_id) WHERE state = 'draft';
CREATE INDEX IF NOT EXISTS idx_group_meeting_minutes_tenant
  ON group_meeting_minutes(organization_id, meeting_id, version DESC);

-- Committee and meeting rows are governance evidence. Direct writes are refused
-- unless the committee engine is servicing the command. Draft minutes remain
-- correctable; approved minutes are immutable and corrected by an addendum.
CREATE OR REPLACE FUNCTION protect_group_committee_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_committee_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_TABLE_NAME = 'group_meeting_minutes' AND TG_OP = 'UPDATE'
    AND OLD.state = 'draft' AND NEW.state = 'draft'
  THEN RETURN NEW;
  END IF;
  RAISE EXCEPTION 'GROUP_COMMITTEE_ENGINE_REQUIRED';
END;
$$;

DROP TRIGGER IF EXISTS protect_group_committees ON group_committees;
CREATE TRIGGER protect_group_committees
  BEFORE UPDATE OR DELETE ON group_committees
  FOR EACH ROW EXECUTE FUNCTION protect_group_committee_evidence();
DROP TRIGGER IF EXISTS protect_group_committee_members ON group_committee_members;
CREATE TRIGGER protect_group_committee_members
  BEFORE UPDATE OR DELETE ON group_committee_members
  FOR EACH ROW EXECUTE FUNCTION protect_group_committee_evidence();
DROP TRIGGER IF EXISTS protect_group_meetings ON group_meetings;
CREATE TRIGGER protect_group_meetings
  BEFORE UPDATE OR DELETE ON group_meetings
  FOR EACH ROW EXECUTE FUNCTION protect_group_committee_evidence();
DROP TRIGGER IF EXISTS protect_group_meeting_attendance ON group_meeting_attendance;
CREATE TRIGGER protect_group_meeting_attendance
  BEFORE UPDATE OR DELETE ON group_meeting_attendance
  FOR EACH ROW EXECUTE FUNCTION protect_group_committee_evidence();
DROP TRIGGER IF EXISTS protect_group_meeting_minutes ON group_meeting_minutes;
CREATE TRIGGER protect_group_meeting_minutes
  BEFORE UPDATE OR DELETE ON group_meeting_minutes
  FOR EACH ROW EXECUTE FUNCTION protect_group_committee_evidence();

CREATE OR REPLACE FUNCTION create_group_committee(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_committee_key TEXT,
  p_display_name TEXT,
  p_mandate TEXT,
  p_delegated_permissions TEXT[],
  p_spending_ceiling_minor_units BIGINT,
  p_spending_ceiling_currency TEXT,
  p_reporting_duties TEXT,
  p_term_ends_at TIMESTAMPTZ,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_committee_id UUID;
  v_group groups;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_committee_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'COMMITTEE_CREATED';
  IF FOUND THEN RETURN v_committee_id; END IF;

  IF p_committee_key !~ '^[a-z][a-z0-9_]{1,47}$' OR p_correlation_id IS NULL
    OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_COMMAND_INVALID'; END IF;
  IF (p_spending_ceiling_minor_units IS NULL) <> (p_spending_ceiling_currency IS NULL)
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_CEILING_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'active'
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_ACTIVE_GROUP_REQUIRED'; END IF;
  IF v_group.current_constitution_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_CONSTITUTION_REQUIRED'; END IF;
  IF p_term_ends_at IS NOT NULL AND p_term_ends_at <= p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_TERM_INVALID'; END IF;

  -- A committee may not hold a permission the group governance role cannot grant.
  IF EXISTS (
    SELECT 1 FROM unnest(p_delegated_permissions) AS requested(permission)
    WHERE requested.permission NOT IN (
      'groups.committee.recommend', 'groups.committee.report',
      'groups.meeting.schedule', 'groups.meeting.minute'
    )
  ) THEN RAISE EXCEPTION 'GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_committees(
    organization_id, group_id, constitution_id, committee_key, display_name,
    mandate, delegated_permissions, spending_ceiling_minor_units,
    spending_ceiling_currency, reporting_duties, term_starts_at, term_ends_at,
    state, created_by, created_at, updated_at
  ) VALUES (
    p_organization_id, p_group_id, v_group.current_constitution_id, p_committee_key,
    p_display_name, p_mandate, COALESCE(p_delegated_permissions, '{}'),
    p_spending_ceiling_minor_units, p_spending_ceiling_currency, p_reporting_duties,
    p_occurred_at, p_term_ends_at, 'active', p_actor_id, p_occurred_at, p_occurred_at
  ) RETURNING id INTO v_committee_id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'COMMITTEE_CREATED',
    'group_committee', v_committee_id,
    jsonb_build_object('committee_key', p_committee_key), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_committee_id;
END;
$$;

CREATE OR REPLACE FUNCTION add_group_committee_member(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_committee_id UUID,
  p_member_id UUID,
  p_committee_role TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_membership_id UUID;
  v_committee group_committees;
  v_member group_members;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_membership_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'COMMITTEE_MEMBER_ADDED';
  IF FOUND THEN RETURN v_membership_id; END IF;

  IF p_committee_role NOT IN ('member', 'chair') OR p_correlation_id IS NULL
    OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_committee FROM group_committees
  WHERE id = p_committee_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND state = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_COMMITTEE_NOT_ACTIVE'; END IF;
  IF v_committee.term_ends_at IS NOT NULL AND v_committee.term_ends_at <= p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_TERM_EXPIRED'; END IF;

  SELECT * INTO v_member FROM group_members
  WHERE id = p_member_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND status = 'active'
    AND is_active = TRUE AND payment_status = 'paid';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;

  IF EXISTS (
    SELECT 1 FROM group_committee_members
    WHERE committee_id = p_committee_id AND member_id = p_member_id AND ends_at IS NULL
  ) THEN RAISE EXCEPTION 'GROUP_COMMITTEE_MEMBER_ALREADY_SERVING'; END IF;
  IF p_committee_role = 'chair' AND EXISTS (
    SELECT 1 FROM group_committee_members
    WHERE committee_id = p_committee_id AND committee_role = 'chair' AND ends_at IS NULL
  ) THEN RAISE EXCEPTION 'GROUP_COMMITTEE_CHAIR_ALREADY_SERVING'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_committee_members(
    organization_id, group_id, committee_id, member_id, user_id, committee_role,
    starts_at, appointed_by, created_at
  ) VALUES (
    p_organization_id, p_group_id, p_committee_id, v_member.id, v_member.user_id,
    p_committee_role, p_occurred_at, p_actor_id, p_occurred_at
  ) RETURNING id INTO v_membership_id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'COMMITTEE_MEMBER_ADDED',
    'group_committee_member', v_membership_id,
    jsonb_build_object(
      'committee_id', p_committee_id, 'member_id', p_member_id,
      'committee_role', p_committee_role
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_membership_id;
END;
$$;

CREATE OR REPLACE FUNCTION end_group_committee_membership(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_membership_id UUID,
  p_reason_code TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result_id UUID;
  v_membership group_committee_members;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_result_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'COMMITTEE_MEMBER_ENDED';
  IF FOUND THEN RETURN v_result_id; END IF;

  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL
    OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_membership FROM group_committee_members
  WHERE id = p_membership_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND ends_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_COMMITTEE_MEMBERSHIP_NOT_ACTIVE'; END IF;
  IF v_membership.starts_at >= p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_MEMBERSHIP_WINDOW_INVALID'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_committee_members
  SET ends_at = p_occurred_at, end_reason_code = p_reason_code
  WHERE id = v_membership.id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'COMMITTEE_MEMBER_ENDED',
    'group_committee_member', v_membership.id,
    jsonb_build_object(
      'committee_id', v_membership.committee_id, 'reason_code', p_reason_code
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_membership.id;
END;
$$;

CREATE OR REPLACE FUNCTION dissolve_group_committee(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_committee_id UUID,
  p_reason_code TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result_id UUID;
  v_committee group_committees;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_result_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'COMMITTEE_DISSOLVED';
  IF FOUND THEN RETURN v_result_id; END IF;

  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL
    OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_COMMITTEE_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_committee FROM group_committees
  WHERE id = p_committee_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND state = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_COMMITTEE_NOT_ACTIVE'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_meetings
    WHERE committee_id = p_committee_id AND state = 'scheduled'
  ) THEN RAISE EXCEPTION 'GROUP_COMMITTEE_HAS_SCHEDULED_MEETINGS'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_committee_members
  SET ends_at = p_occurred_at, end_reason_code = 'COMMITTEE_DISSOLVED'
  WHERE committee_id = p_committee_id AND ends_at IS NULL;
  UPDATE group_committees
  SET state = 'dissolved', dissolved_at = p_occurred_at,
    dissolution_reason_code = p_reason_code, updated_at = p_occurred_at
  WHERE id = v_committee.id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'COMMITTEE_DISSOLVED',
    'group_committee', v_committee.id,
    jsonb_build_object('reason_code', p_reason_code), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_committee.id;
END;
$$;

-- Scheduling snapshots the eligible attendee count so a later membership change
-- cannot retroactively alter whether a held meeting reached quorum.
CREATE OR REPLACE FUNCTION schedule_group_meeting(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_meeting_type TEXT,
  p_committee_id UUID,
  p_title TEXT,
  p_agenda JSONB,
  p_scheduled_at TIMESTAMPTZ,
  p_required_notice_hours INTEGER,
  p_emergency_reason TEXT,
  p_location TEXT,
  p_quorum_numerator INTEGER,
  p_quorum_denominator INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_meeting_id UUID;
  v_group groups;
  v_eligible INTEGER;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_meeting_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'MEETING_SCHEDULED';
  IF FOUND THEN RETURN v_meeting_id; END IF;

  IF p_meeting_type NOT IN ('general', 'committee', 'special', 'emergency')
    OR p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_required_notice_hours IS NULL OR p_required_notice_hours < 0
    OR p_quorum_numerator IS NULL OR p_quorum_denominator IS NULL
    OR p_quorum_numerator < 1 OR p_quorum_denominator < 1
    OR p_quorum_numerator > p_quorum_denominator
    OR jsonb_typeof(COALESCE(p_agenda, '[]'::JSONB)) <> 'array'
  THEN RAISE EXCEPTION 'GROUP_MEETING_COMMAND_INVALID'; END IF;
  IF (p_meeting_type = 'emergency') <> (p_emergency_reason IS NOT NULL)
  THEN RAISE EXCEPTION 'GROUP_MEETING_EMERGENCY_REASON_REQUIRED'; END IF;
  IF (p_meeting_type = 'committee') <> (p_committee_id IS NOT NULL)
  THEN RAISE EXCEPTION 'GROUP_MEETING_COMMITTEE_LINK_INVALID'; END IF;
  IF p_scheduled_at <= p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_MEETING_SCHEDULE_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'active'
  THEN RAISE EXCEPTION 'GROUP_MEETING_ACTIVE_GROUP_REQUIRED'; END IF;

  -- Only an emergency meeting may shorten the notice window, and it must say why.
  IF p_meeting_type <> 'emergency'
    AND p_scheduled_at < p_occurred_at + make_interval(hours => p_required_notice_hours)
  THEN RAISE EXCEPTION 'GROUP_MEETING_NOTICE_TOO_SHORT'; END IF;

  IF p_committee_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM group_committees
      WHERE id = p_committee_id AND organization_id = p_organization_id
        AND group_id = p_group_id AND state = 'active'
    ) THEN RAISE EXCEPTION 'GROUP_COMMITTEE_NOT_ACTIVE'; END IF;
    SELECT count(*) INTO v_eligible FROM group_committee_members
    WHERE committee_id = p_committee_id AND ends_at IS NULL;
  ELSE
    SELECT count(*) INTO v_eligible FROM group_members
    WHERE organization_id = p_organization_id AND group_id = p_group_id
      AND status = 'active' AND is_active = TRUE AND payment_status = 'paid';
  END IF;
  IF v_eligible = 0 THEN RAISE EXCEPTION 'GROUP_MEETING_NO_ELIGIBLE_ATTENDEES'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_meetings(
    organization_id, group_id, committee_id, meeting_type, title, agenda,
    scheduled_at, notice_issued_at, required_notice_hours, emergency_reason,
    location, quorum_numerator, quorum_denominator, eligible_attendee_count,
    state, created_by, created_at, updated_at
  ) VALUES (
    p_organization_id, p_group_id, p_committee_id, p_meeting_type, p_title,
    COALESCE(p_agenda, '[]'::JSONB), p_scheduled_at, p_occurred_at,
    p_required_notice_hours, p_emergency_reason, p_location,
    p_quorum_numerator, p_quorum_denominator, v_eligible,
    'scheduled', p_actor_id, p_occurred_at, p_occurred_at
  ) RETURNING id INTO v_meeting_id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_SCHEDULED',
    'group_meeting', v_meeting_id,
    jsonb_build_object(
      'meeting_type', p_meeting_type, 'scheduled_at', p_scheduled_at,
      'eligible_attendee_count', v_eligible
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_meeting_id;
END;
$$;

-- Attendance is a record of presence only. It never confers a financial approval;
-- decisions continue to require GT-03 proposals and ballots.
CREATE OR REPLACE FUNCTION record_group_meeting_attendance(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_meeting_id UUID,
  p_member_id UUID,
  p_attendance_status TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_attendance_id UUID;
  v_meeting group_meetings;
  v_member group_members;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_attendance_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'MEETING_ATTENDANCE_RECORDED';
  IF FOUND THEN RETURN v_attendance_id; END IF;

  IF p_attendance_status NOT IN ('present', 'absent', 'apology', 'proxy')
    OR p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_MEETING_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_meeting FROM group_meetings
  WHERE id = p_meeting_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND state = 'scheduled' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEETING_NOT_SCHEDULED'; END IF;

  SELECT * INTO v_member FROM group_members
  WHERE id = p_member_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND status = 'active'
    AND is_active = TRUE AND payment_status = 'paid';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;
  IF v_meeting.committee_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM group_committee_members
    WHERE committee_id = v_meeting.committee_id AND member_id = p_member_id
      AND ends_at IS NULL
  ) THEN RAISE EXCEPTION 'GROUP_MEETING_ATTENDEE_NOT_ELIGIBLE'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_meeting_attendance
    WHERE meeting_id = p_meeting_id AND member_id = p_member_id
  ) THEN RAISE EXCEPTION 'GROUP_MEETING_ATTENDANCE_ALREADY_RECORDED'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_meeting_attendance(
    organization_id, group_id, meeting_id, member_id, user_id,
    attendance_status, recorded_by, recorded_at
  ) VALUES (
    p_organization_id, p_group_id, p_meeting_id, v_member.id, v_member.user_id,
    p_attendance_status, p_actor_id, p_occurred_at
  ) RETURNING id INTO v_attendance_id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_ATTENDANCE_RECORDED',
    'group_meeting_attendance', v_attendance_id,
    jsonb_build_object(
      'meeting_id', p_meeting_id, 'attendance_status', p_attendance_status
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_attendance_id;
END;
$$;

-- Quorum uses integer comparison against the snapshot taken at scheduling.
CREATE OR REPLACE FUNCTION hold_group_meeting(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_meeting_id UUID,
  p_expected_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_meetings
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_meeting group_meetings;
  v_present INTEGER;
  v_quorum_met BOOLEAN;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT meeting.* INTO v_meeting
  FROM group_governance_events AS event
  JOIN group_meetings AS meeting ON meeting.id = event.resource_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id
    AND event.event_type = 'MEETING_HELD';
  IF FOUND THEN RETURN v_meeting; END IF;

  IF p_correlation_id IS NULL OR p_occurred_at IS NULL OR p_expected_version < 1
  THEN RAISE EXCEPTION 'GROUP_MEETING_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_meeting FROM group_meetings
  WHERE id = p_meeting_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEETING_NOT_FOUND'; END IF;
  IF v_meeting.state <> 'scheduled' OR v_meeting.state_version <> p_expected_version
  THEN RAISE EXCEPTION 'GROUP_MEETING_VERSION_CONFLICT'; END IF;

  SELECT count(*) INTO v_present FROM group_meeting_attendance
  WHERE meeting_id = p_meeting_id AND attendance_status = 'present';
  v_quorum_met := v_present * v_meeting.quorum_denominator
    >= v_meeting.eligible_attendee_count * v_meeting.quorum_numerator;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_meetings
  SET state = 'held', held_at = p_occurred_at, quorum_met = v_quorum_met,
    state_version = state_version + 1, updated_at = p_occurred_at
  WHERE id = v_meeting.id RETURNING * INTO v_meeting;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_HELD',
    'group_meeting', v_meeting.id,
    jsonb_build_object(
      'present_count', v_present,
      'eligible_attendee_count', v_meeting.eligible_attendee_count,
      'quorum_met', v_quorum_met
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_meeting;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_group_meeting(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_meeting_id UUID,
  p_expected_version INTEGER,
  p_reason_code TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result_id UUID;
  v_meeting group_meetings;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_result_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'MEETING_CANCELLED';
  IF FOUND THEN RETURN v_result_id; END IF;

  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL
    OR p_occurred_at IS NULL OR p_expected_version < 1
  THEN RAISE EXCEPTION 'GROUP_MEETING_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_meeting FROM group_meetings
  WHERE id = p_meeting_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEETING_NOT_FOUND'; END IF;
  IF v_meeting.state <> 'scheduled' OR v_meeting.state_version <> p_expected_version
  THEN RAISE EXCEPTION 'GROUP_MEETING_VERSION_CONFLICT'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_meetings
  SET state = 'cancelled', cancelled_at = p_occurred_at,
    cancellation_reason_code = p_reason_code,
    state_version = state_version + 1, updated_at = p_occurred_at
  WHERE id = v_meeting.id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_CANCELLED',
    'group_meeting', v_meeting.id,
    jsonb_build_object('reason_code', p_reason_code), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_meeting.id;
END;
$$;

-- Draft minutes are correctable in place by the engine. Approval freezes the row;
-- a later correction must be an addendum that links to the approved original.
CREATE OR REPLACE FUNCTION draft_group_meeting_minutes(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_meeting_id UUID,
  p_content TEXT,
  p_resolutions JSONB,
  p_corrects_minutes_id UUID,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_minutes_id UUID;
  v_meeting group_meetings;
  v_kind TEXT := 'minutes';
  v_version INTEGER;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_minutes_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'MEETING_MINUTES_DRAFTED';
  IF FOUND THEN RETURN v_minutes_id; END IF;

  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_content IS NULL OR char_length(p_content) = 0
    OR jsonb_typeof(COALESCE(p_resolutions, '[]'::JSONB)) <> 'array'
  THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_meeting FROM group_meetings
  WHERE id = p_meeting_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEETING_NOT_FOUND'; END IF;
  IF v_meeting.state <> 'held'
  THEN RAISE EXCEPTION 'GROUP_MEETING_NOT_HELD'; END IF;

  IF p_corrects_minutes_id IS NOT NULL THEN
    v_kind := 'addendum';
    IF NOT EXISTS (
      SELECT 1 FROM group_meeting_minutes
      WHERE id = p_corrects_minutes_id AND meeting_id = p_meeting_id
        AND organization_id = p_organization_id AND state = 'approved'
    ) THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_CORRECTION_TARGET_INVALID'; END IF;
  ELSIF EXISTS (
    SELECT 1 FROM group_meeting_minutes
    WHERE meeting_id = p_meeting_id AND state = 'approved' AND minutes_kind = 'minutes'
  ) THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_ALREADY_APPROVED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM group_meeting_minutes
    WHERE meeting_id = p_meeting_id AND state = 'draft'
  ) THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_DRAFT_EXISTS'; END IF;

  SELECT COALESCE(max(version), 0) + 1 INTO v_version
  FROM group_meeting_minutes WHERE meeting_id = p_meeting_id;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  INSERT INTO group_meeting_minutes(
    organization_id, group_id, meeting_id, version, minutes_kind,
    corrects_minutes_id, content, resolutions, state, created_by,
    created_at, updated_at
  ) VALUES (
    p_organization_id, p_group_id, p_meeting_id, v_version, v_kind,
    p_corrects_minutes_id, p_content, COALESCE(p_resolutions, '[]'::JSONB),
    'draft', p_actor_id, p_occurred_at, p_occurred_at
  ) RETURNING id INTO v_minutes_id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_MINUTES_DRAFTED',
    'group_meeting_minutes', v_minutes_id,
    jsonb_build_object(
      'meeting_id', p_meeting_id, 'version', v_version, 'minutes_kind', v_kind
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_minutes_id;
END;
$$;

CREATE OR REPLACE FUNCTION approve_group_meeting_minutes(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_minutes_id UUID,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result_id UUID;
  v_minutes group_meeting_minutes;
  v_previous_setting TEXT;
  v_previous_governance TEXT;
BEGIN
  SELECT resource_id INTO v_result_id FROM group_governance_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'MEETING_MINUTES_APPROVED';
  IF FOUND THEN RETURN v_result_id; END IF;

  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_minutes FROM group_meeting_minutes
  WHERE id = p_minutes_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND state = 'draft' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_NOT_DRAFT'; END IF;
  -- The drafter cannot self-approve their own record of the meeting.
  IF v_minutes.created_by = p_actor_id
  THEN RAISE EXCEPTION 'GROUP_MEETING_MINUTES_INDEPENDENT_APPROVAL_REQUIRED'; END IF;

  v_previous_setting := current_setting('microfams.group_committee_engine', TRUE);
  v_previous_governance := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_committee_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);
  UPDATE group_meeting_minutes
  SET state = 'approved', approved_by = p_actor_id, approved_at = p_occurred_at,
    updated_at = p_occurred_at
  WHERE id = v_minutes.id;

  INSERT INTO group_governance_events(
    organization_id, group_id, actor_id, event_type, resource_type, resource_id,
    evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_actor_id, 'MEETING_MINUTES_APPROVED',
    'group_meeting_minutes', v_minutes.id,
    jsonb_build_object(
      'meeting_id', v_minutes.meeting_id, 'version', v_minutes.version
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_committee_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM set_config('microfams.group_governance_engine', COALESCE(v_previous_governance, ''), TRUE);
  RETURN v_minutes.id;
END;
$$;

ALTER TABLE group_committees ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_committee_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_meeting_attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_meeting_minutes ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'group_committees', 'group_committee_members', 'group_meetings',
    'group_meeting_attendance', 'group_meeting_minutes'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT USING (has_active_organization_membership(organization_id))',
      table_name
    );
    EXECUTE format('REVOKE ALL ON %I FROM PUBLIC, anon, authenticated', table_name);
    EXECUTE format('GRANT SELECT ON %I TO service_role', table_name);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I FROM service_role', table_name);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION create_group_committee(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT[], BIGINT, TEXT, TEXT, TIMESTAMPTZ, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION add_group_committee_member(
  UUID, UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION end_group_committee_membership(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION dissolve_group_committee(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_group_committee(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT[], BIGINT, TEXT, TEXT, TIMESTAMPTZ, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION add_group_committee_member(
  UUID, UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION end_group_committee_membership(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION dissolve_group_committee(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO service_role;

REVOKE ALL ON FUNCTION schedule_group_meeting(
  UUID, UUID, UUID, TEXT, UUID, TEXT, JSONB, TIMESTAMPTZ, INTEGER, TEXT, TEXT,
  INTEGER, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_group_meeting_attendance(
  UUID, UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hold_group_meeting(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cancel_group_meeting(
  UUID, UUID, UUID, UUID, INTEGER, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION draft_group_meeting_minutes(
  UUID, UUID, UUID, UUID, TEXT, JSONB, UUID, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION approve_group_meeting_minutes(
  UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION schedule_group_meeting(
  UUID, UUID, UUID, TEXT, UUID, TEXT, JSONB, TIMESTAMPTZ, INTEGER, TEXT, TEXT,
  INTEGER, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION record_group_meeting_attendance(
  UUID, UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION hold_group_meeting(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION cancel_group_meeting(
  UUID, UUID, UUID, UUID, INTEGER, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION draft_group_meeting_minutes(
  UUID, UUID, UUID, UUID, TEXT, JSONB, UUID, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION approve_group_meeting_minutes(
  UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) TO service_role;
