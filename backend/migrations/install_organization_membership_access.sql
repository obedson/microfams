-- Owner-governed organization membership role and permission administration.
SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION update_organization_membership_access(
  p_organization_id UUID,
  p_actor_id UUID,
  p_membership_id UUID,
  p_role TEXT,
  p_permissions TEXT[],
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_actor_role TEXT;
  v_target organization_memberships;
  v_permissions TEXT[];
BEGIN
  IF p_organization_id IS NULL
     OR p_actor_id IS NULL
     OR p_membership_id IS NULL
     OR p_role IS NULL
     OR p_role NOT IN (
       'admin', 'finance_manager', 'program_manager',
       'farm_manager', 'auditor', 'member', 'viewer'
     )
     OR COALESCE(array_length(p_permissions, 1), 0) > 64
     OR EXISTS (
       SELECT 1
       FROM unnest(COALESCE(p_permissions, '{}'::TEXT[])) AS permission
       WHERE permission IS NULL
          OR permission <> trim(permission)
          OR permission !~ '^[a-z][a-z0-9_]*(\.(\*|[a-z][a-z0-9_]*))+$'
     )
  THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_ACCESS_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = p_organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_NOT_ACTIVE';
  END IF;

  SELECT role INTO v_actor_role
  FROM organization_memberships
  WHERE organization_id = p_organization_id
    AND user_id = p_actor_id
    AND status = 'active';
  IF v_actor_role IS NULL OR v_actor_role <> 'owner' THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_PERMISSION_DENIED';
  END IF;

  SELECT * INTO v_target
  FROM organization_memberships
  WHERE id = p_membership_id
    AND organization_id = p_organization_id
    AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_NOT_FOUND';
  END IF;
  IF v_target.role = 'owner' THEN
    RAISE EXCEPTION 'ORGANIZATION_OWNERSHIP_WORKFLOW_REQUIRED';
  END IF;

  SELECT COALESCE(array_agg(permission ORDER BY permission), '{}'::TEXT[])
  INTO v_permissions
  FROM (
    SELECT DISTINCT permission
    FROM unnest(COALESCE(p_permissions, '{}'::TEXT[])) AS permission
  ) AS normalized;

  UPDATE organization_memberships
  SET role = p_role,
      permissions = v_permissions,
      updated_at = p_occurred_at
  WHERE id = v_target.id;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  ) VALUES (
    p_organization_id, p_actor_id, 'organization.membership.access_updated',
    'organization_membership', v_target.id::TEXT,
    jsonb_build_object(
      'role', v_target.role,
      'permissions', to_jsonb(v_target.permissions)
    ),
    jsonb_build_object(
      'role', p_role,
      'permissions', to_jsonb(v_permissions)
    ),
    p_occurred_at
  );

  RETURN jsonb_build_object(
    'id', v_target.id,
    'user_id', v_target.user_id,
    'role', p_role,
    'permissions', to_jsonb(v_permissions),
    'status', v_target.status,
    'joined_at', v_target.joined_at,
    'updated_at', p_occurred_at
  );
END;
$$;

REVOKE ALL ON FUNCTION update_organization_membership_access(
  UUID, UUID, UUID, TEXT, TEXT[], TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION update_organization_membership_access(
  UUID, UUID, UUID, TEXT, TEXT[], TIMESTAMPTZ
) TO service_role;
