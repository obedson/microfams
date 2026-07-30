BEGIN;

DO $$
DECLARE
  v_organization_id UUID;
  v_actor_id UUID;
  v_other_organization_id UUID;
  v_group_one UUID;
  v_group_two UUID;
  v_state TEXT;
  v_version INTEGER;
BEGIN
  SELECT membership.organization_id, membership.user_id
  INTO v_organization_id, v_actor_id
  FROM organization_memberships AS membership
  JOIN organizations AS organization ON organization.id = membership.organization_id
  WHERE membership.status = 'active'
    AND organization.status = 'active'
    AND membership.role IN ('owner', 'admin')
  ORDER BY membership.created_at
  LIMIT 1;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'group lifecycle tenant fixture is unavailable';
  END IF;
  SELECT id INTO v_other_organization_id
  FROM organizations
  WHERE id <> v_organization_id
    AND NOT EXISTS (
      SELECT 1
      FROM organization_memberships
      WHERE organization_id = organizations.id
        AND user_id = v_actor_id
        AND status = 'active'
    )
  ORDER BY created_at
  LIMIT 1;
  IF v_other_organization_id IS NULL THEN
    INSERT INTO organizations(name, slug, type, created_by)
    VALUES (
      'GT-01 Other Tenant',
      'gt-01-other-' || substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 12),
      'cooperative',
      v_actor_id
    ) RETURNING id INTO v_other_organization_id;
  END IF;

  BEGIN
    INSERT INTO groups(
      name, category, creator_id, organization_id, max_members
    ) VALUES (
      'GT-01 Invalid Tenant Group',
      'cooperative',
      v_actor_id,
      v_other_organization_id,
      20
    );
    RAISE EXCEPTION 'cross-tenant group creator was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant group creator was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_CREATOR_TENANT_MEMBERSHIP_REQUIRED%' THEN RAISE; END IF;
  END;

  INSERT INTO groups(
    name, category, creator_id, organization_id, max_members
  ) VALUES (
    'GT-01 Group One', 'cooperative', v_actor_id, v_organization_id, 20
  ) RETURNING id INTO v_group_one;
  INSERT INTO groups(
    name, category, creator_id, organization_id, max_members
  ) VALUES (
    'GT-01 Group Two', 'cooperative', v_actor_id, v_organization_id, 20
  ) RETURNING id INTO v_group_two;
  IF NOT EXISTS (
    SELECT 1 FROM public_group_directory WHERE id = v_group_one
  ) THEN RAISE EXCEPTION 'active group is missing from public projection'; END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'public_group_directory'
      AND column_name IN (
        'creator_id', 'group_fund_balance', 'contribution_amount',
        'lifecycle_reason_code'
      )
  ) THEN RAISE EXCEPTION 'public group projection exposes private columns'; END IF;

  INSERT INTO group_members(organization_id, group_id, user_id)
  VALUES
    (v_organization_id, v_group_one, v_actor_id),
    (v_organization_id, v_group_two, v_actor_id);
  IF (
    SELECT count(*) FROM group_members
    WHERE user_id = v_actor_id AND group_id IN (v_group_one, v_group_two)
  ) <> 2 THEN
    RAISE EXCEPTION 'GT-01 multi-group membership was not preserved';
  END IF;

  BEGIN
    INSERT INTO group_members(organization_id, group_id, user_id)
    VALUES (v_other_organization_id, v_group_one, v_actor_id);
    RAISE EXCEPTION 'cross-tenant group membership was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant group membership was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_TENANT_MISMATCH%' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE groups SET lifecycle_state = 'suspended' WHERE id = v_group_one;
    RAISE EXCEPTION 'direct group lifecycle update was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'direct group lifecycle update was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_LIFECYCLE_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;

  SELECT lifecycle_version INTO v_version FROM groups WHERE id = v_group_one;
  PERFORM transition_group_lifecycle(
    v_organization_id, v_group_one, v_actor_id, 'suspended',
    'SCHEMA_TEST_SUSPEND', v_version, gen_random_uuid(),
    TIMESTAMPTZ '2026-07-30 13:45:00+00'
  );
  SELECT lifecycle_state, lifecycle_version INTO v_state, v_version
  FROM groups WHERE id = v_group_one;
  IF v_state <> 'suspended' OR NOT EXISTS (
    SELECT 1 FROM group_lifecycle_events
    WHERE group_id = v_group_one AND from_state = 'active'
      AND to_state = 'suspended' AND lifecycle_version = v_version
  ) OR EXISTS (
    SELECT 1 FROM public_group_directory WHERE id = v_group_one
  ) THEN RAISE EXCEPTION 'group suspension evidence is incomplete'; END IF;

  PERFORM transition_group_lifecycle(
    v_organization_id, v_group_one, v_actor_id, 'active',
    'SCHEMA_TEST_REACTIVATE', v_version, gen_random_uuid(),
    TIMESTAMPTZ '2026-07-30 13:46:00+00'
  );
  IF NOT EXISTS (
    SELECT 1 FROM groups
    WHERE id = v_group_one AND lifecycle_state = 'active' AND is_active
  ) OR (
    SELECT count(*) FROM group_lifecycle_events WHERE group_id = v_group_one
  ) <> 3 THEN
    RAISE EXCEPTION 'group lifecycle history is incomplete';
  END IF;
END $$;

ROLLBACK;
SELECT 'group lifecycle foundation schema tests passed' AS result;
