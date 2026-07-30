BEGIN;

DO $$
DECLARE
  v_organization_id UUID;
  v_actor_id UUID;
  v_group_id UUID;
  v_member_id UUID;
  v_constitution_id UUID;
  v_assignment_id UUID;
  v_repeat_assignment_id UUID;
  v_group groups;
BEGIN
  SELECT membership.organization_id, membership.user_id
  INTO v_organization_id, v_actor_id
  FROM organization_memberships AS membership
  JOIN organizations AS organization ON organization.id = membership.organization_id
  WHERE membership.status = 'active' AND organization.status = 'active'
    AND membership.role = 'owner'
  ORDER BY membership.created_at
  LIMIT 1;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'GT-02A tenant fixture is unavailable';
  END IF;

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
  VALUES ('GT-02A Draft Group', 'cooperative', v_actor_id, v_organization_id, 20)
  RETURNING id INTO v_group_id;
  SELECT * INTO v_group FROM groups WHERE id = v_group_id;
  IF v_group.lifecycle_state <> 'draft' OR v_group.is_active
    OR v_group.current_constitution_id IS NOT NULL
  THEN RAISE EXCEPTION 'new group did not start as a private draft'; END IF;
  IF EXISTS (SELECT 1 FROM public_group_directory WHERE id = v_group_id)
  THEN RAISE EXCEPTION 'draft group leaked into public discovery'; END IF;

  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active,
    payment_status, amount_paid
  ) VALUES (
    v_organization_id, v_group_id, v_actor_id, 'owner', 'active', TRUE,
    'paid', 1000
  ) RETURNING id INTO v_member_id;

  v_constitution_id := adopt_initial_group_constitution(
    v_organization_id, v_group_id, v_actor_id, 'GT-02A Constitution',
    jsonb_build_object(
      'minimum_members', 1,
      'ordinary_quorum_bps', 5000,
      'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667,
      'special_approval_bps', 6667,
      'vote_change_allowed', FALSE
    ),
    '00000000-0000-4000-8000-000000000211',
    TIMESTAMPTZ '2026-07-30 15:00:00+00'
  );
  IF NOT EXISTS (
    SELECT 1 FROM group_constitutions
    WHERE id = v_constitution_id AND status = 'effective'
      AND adoption_basis = 'initial_owner_adoption'
  ) OR (
    SELECT current_constitution_id FROM groups WHERE id = v_group_id
  ) <> v_constitution_id
  THEN RAISE EXCEPTION 'initial constitution adoption evidence is incomplete'; END IF;

  BEGIN
    PERFORM activate_group_with_constitution(
      v_organization_id, v_group_id, v_actor_id, 1,
      '00000000-0000-4000-8000-000000000212',
      TIMESTAMPTZ '2026-07-30 15:01:00+00'
    );
    RAISE EXCEPTION 'group activated without required offices';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'group activated without required offices' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_REQUIRED_OFFICES_INCOMPLETE%' THEN RAISE; END IF;
  END;

  v_assignment_id := appoint_initial_group_office(
    v_organization_id, v_group_id, v_actor_id, 'chair', v_member_id, NULL,
    '00000000-0000-4000-8000-000000000213',
    TIMESTAMPTZ '2026-07-30 15:02:00+00'
  );
  v_repeat_assignment_id := appoint_initial_group_office(
    v_organization_id, v_group_id, v_actor_id, 'chair', v_member_id, NULL,
    '00000000-0000-4000-8000-000000000213',
    TIMESTAMPTZ '2026-07-30 15:02:00+00'
  );
  IF v_assignment_id <> v_repeat_assignment_id
  THEN RAISE EXCEPTION 'office appointment was not idempotent'; END IF;
  PERFORM appoint_initial_group_office(
    v_organization_id, v_group_id, v_actor_id, 'secretary', v_member_id, NULL,
    '00000000-0000-4000-8000-000000000214',
    TIMESTAMPTZ '2026-07-30 15:03:00+00'
  );
  PERFORM appoint_initial_group_office(
    v_organization_id, v_group_id, v_actor_id, 'treasurer', v_member_id, NULL,
    '00000000-0000-4000-8000-000000000215',
    TIMESTAMPTZ '2026-07-30 15:04:00+00'
  );

  SELECT * INTO v_group FROM activate_group_with_constitution(
    v_organization_id, v_group_id, v_actor_id, 1,
    '00000000-0000-4000-8000-000000000216',
    TIMESTAMPTZ '2026-07-30 15:05:00+00'
  );
  IF v_group.lifecycle_state <> 'active' OR v_group.lifecycle_version <> 2
    OR NOT EXISTS (SELECT 1 FROM public_group_directory WHERE id = v_group_id)
    OR NOT EXISTS (
      SELECT 1 FROM group_governance_events
      WHERE group_id = v_group_id AND event_type = 'GROUP_ACTIVATED'
    )
  THEN RAISE EXCEPTION 'constitution-gated activation evidence is incomplete'; END IF;

  BEGIN
    UPDATE group_constitutions SET name = 'Tampered'
    WHERE id = v_constitution_id;
    RAISE EXCEPTION 'effective constitution mutation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'effective constitution mutation was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_GOVERNANCE_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;

ROLLBACK;

SELECT 'group constitution and offices schema tests passed' AS result;
