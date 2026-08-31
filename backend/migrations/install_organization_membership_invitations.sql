-- Tenant-bound organization membership invitations with hashed, single-use tokens.
SET search_path = public, extensions;

ALTER TABLE organization_invitations
  ADD COLUMN IF NOT EXISTS correlation_id UUID,
  ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

ALTER TABLE organization_invitations
  DROP CONSTRAINT IF EXISTS organization_invitations_token_hash_check;
ALTER TABLE organization_invitations
  ADD CONSTRAINT organization_invitations_token_hash_check
  CHECK (token_hash ~ '^[0-9a-f]{64}$');
ALTER TABLE organization_invitations
  DROP CONSTRAINT IF EXISTS organization_invitations_terminal_state_check;
ALTER TABLE organization_invitations
  ADD CONSTRAINT organization_invitations_terminal_state_check CHECK (
    (status = 'accepted') = (accepted_at IS NOT NULL)
    AND (status = 'revoked') = (revoked_at IS NOT NULL)
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_organization_invitation_correlation
  ON organization_invitations(organization_id, correlation_id)
  WHERE correlation_id IS NOT NULL;

CREATE OR REPLACE FUNCTION assert_organization_membership_administrator(
  p_organization_id UUID,
  p_actor_id UUID
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_role TEXT;
BEGIN
  SELECT role INTO v_role
  FROM organization_memberships
  WHERE organization_id = p_organization_id
    AND user_id = p_actor_id
    AND status = 'active';

  IF v_role IS NULL OR v_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_PERMISSION_DENIED';
  END IF;

  RETURN v_role;
END;
$$;

CREATE OR REPLACE FUNCTION create_organization_membership_invitation(
  p_organization_id UUID,
  p_actor_id UUID,
  p_email TEXT,
  p_role TEXT,
  p_permissions TEXT[],
  p_token_hash TEXT,
  p_expires_at TIMESTAMPTZ,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_actor_role TEXT;
  v_email TEXT := lower(trim(p_email));
  v_invitation_id UUID;
BEGIN
  IF p_email IS NULL
     OR p_role IS NULL
     OR p_token_hash IS NULL
     OR p_expires_at IS NULL
     OR p_correlation_id IS NULL
     OR p_token_hash !~ '^[0-9a-f]{64}$'
     OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     OR p_expires_at <= p_occurred_at
     OR p_expires_at > p_occurred_at + INTERVAL '30 days'
     OR p_role NOT IN (
       'owner', 'admin', 'finance_manager', 'program_manager',
       'farm_manager', 'auditor', 'member', 'viewer'
     )
     OR EXISTS (
       SELECT 1 FROM unnest(COALESCE(p_permissions, '{}'::TEXT[])) AS permission
       WHERE permission !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
     )
  THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_COMMAND_INVALID';
  END IF;

  SELECT id INTO v_invitation_id
  FROM organization_invitations
  WHERE organization_id = p_organization_id
    AND correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN jsonb_build_object('invitation_id', v_invitation_id, 'created', FALSE);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = p_organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_NOT_ACTIVE';
  END IF;

  v_actor_role := assert_organization_membership_administrator(
    p_organization_id, p_actor_id
  );
  IF p_role = 'owner' AND v_actor_role <> 'owner' THEN
    RAISE EXCEPTION 'ORGANIZATION_OWNER_INVITATION_REQUIRES_OWNER';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM organization_memberships AS membership
    JOIN users AS account ON account.id = membership.user_id
    WHERE membership.organization_id = p_organization_id
      AND lower(account.email) = v_email
      AND membership.status <> 'removed'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_ALREADY_EXISTS';
  END IF;

  UPDATE organization_invitations
  SET status = 'expired'
  WHERE organization_id = p_organization_id
    AND lower(email) = v_email
    AND status = 'pending'
    AND expires_at <= p_occurred_at;

  IF EXISTS (
    SELECT 1 FROM organization_invitations
    WHERE organization_id = p_organization_id
      AND lower(email) = v_email
      AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_ALREADY_PENDING';
  END IF;

  INSERT INTO organization_invitations(
    organization_id, email, role, permissions, token_hash, invited_by,
    expires_at, correlation_id, created_at
  ) VALUES (
    p_organization_id, v_email, p_role, COALESCE(p_permissions, '{}'::TEXT[]),
    p_token_hash, p_actor_id, p_expires_at, p_correlation_id, p_occurred_at
  ) RETURNING id INTO v_invitation_id;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value,
    occurred_at
  ) VALUES (
    p_organization_id, p_actor_id, 'organization.invitation.created',
    'organization_invitation', v_invitation_id::TEXT,
    jsonb_build_object('email', v_email, 'role', p_role, 'expiresAt', p_expires_at),
    p_occurred_at
  );

  RETURN jsonb_build_object('invitation_id', v_invitation_id, 'created', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION accept_organization_membership_invitation(
  p_actor_id UUID,
  p_token_hash TEXT,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_invitation organization_invitations;
  v_actor_email TEXT;
  v_membership_id UUID;
BEGIN
  IF p_actor_id IS NULL OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_COMMAND_INVALID';
  END IF;

  SELECT lower(email) INTO v_actor_email FROM users WHERE id = p_actor_id;
  IF v_actor_email IS NULL THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_NOT_FOUND';
  END IF;

  SELECT * INTO v_invitation
  FROM organization_invitations
  WHERE token_hash = p_token_hash
  FOR UPDATE;
  IF NOT FOUND OR lower(v_invitation.email) <> v_actor_email THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_NOT_FOUND';
  END IF;

  IF v_invitation.status = 'accepted' THEN
    SELECT id INTO v_membership_id
    FROM organization_memberships
    WHERE organization_id = v_invitation.organization_id
      AND user_id = p_actor_id;
    RETURN jsonb_build_object(
      'organization_id', v_invitation.organization_id,
      'membership_id', v_membership_id,
      'accepted', FALSE
    );
  END IF;

  IF v_invitation.status <> 'pending'
     OR v_invitation.expires_at <= p_occurred_at
  THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_UNAVAILABLE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = v_invitation.organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_NOT_ACTIVE';
  END IF;

  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, invited_by,
    joined_at, updated_at
  ) VALUES (
    v_invitation.organization_id, p_actor_id, v_invitation.role,
    v_invitation.permissions, 'active', v_invitation.invited_by,
    p_occurred_at, p_occurred_at
  )
  ON CONFLICT (organization_id, user_id) DO UPDATE SET
    role = EXCLUDED.role,
    permissions = EXCLUDED.permissions,
    status = 'active',
    invited_by = EXCLUDED.invited_by,
    joined_at = EXCLUDED.joined_at,
    updated_at = EXCLUDED.updated_at
  WHERE organization_memberships.status = 'removed'
  RETURNING id INTO v_membership_id;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'ORGANIZATION_MEMBERSHIP_ALREADY_EXISTS';
  END IF;

  UPDATE organization_invitations
  SET status = 'accepted', accepted_at = p_occurred_at
  WHERE id = v_invitation.id;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value,
    occurred_at
  ) VALUES (
    v_invitation.organization_id, p_actor_id, 'organization.invitation.accepted',
    'organization_membership', v_membership_id::TEXT,
    jsonb_build_object('invitationId', v_invitation.id, 'role', v_invitation.role),
    p_occurred_at
  );

  RETURN jsonb_build_object(
    'organization_id', v_invitation.organization_id,
    'membership_id', v_membership_id,
    'accepted', TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION revoke_organization_membership_invitation(
  p_organization_id UUID,
  p_actor_id UUID,
  p_invitation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_invitation organization_invitations;
BEGIN
  PERFORM assert_organization_membership_administrator(
    p_organization_id, p_actor_id
  );
  SELECT * INTO v_invitation FROM organization_invitations
  WHERE id = p_invitation_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORGANIZATION_INVITATION_NOT_FOUND'; END IF;
  IF v_invitation.status = 'revoked' THEN RETURN v_invitation.id; END IF;
  IF v_invitation.status <> 'pending' THEN
    RAISE EXCEPTION 'ORGANIZATION_INVITATION_UNAVAILABLE';
  END IF;

  UPDATE organization_invitations
  SET status = 'revoked', revoked_at = p_occurred_at
  WHERE id = v_invitation.id;
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  ) VALUES (
    p_organization_id, p_actor_id, 'organization.invitation.revoked',
    'organization_invitation', v_invitation.id::TEXT,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'revoked'), p_occurred_at
  );
  RETURN v_invitation.id;
END;
$$;

REVOKE INSERT, UPDATE, DELETE ON organization_memberships,
  organization_invitations, organization_audit_log FROM service_role;
GRANT SELECT ON organization_invitations TO service_role;
REVOKE ALL ON FUNCTION assert_organization_membership_administrator(UUID,UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION create_organization_membership_invitation(UUID,UUID,TEXT,TEXT,TEXT[],TEXT,TIMESTAMPTZ,UUID,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION accept_organization_membership_invitation(UUID,TEXT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION revoke_organization_membership_invitation(UUID,UUID,UUID,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_organization_membership_invitation(UUID,UUID,TEXT,TEXT,TEXT[],TEXT,TIMESTAMPTZ,UUID,TIMESTAMPTZ)
  TO service_role;
GRANT EXECUTE ON FUNCTION accept_organization_membership_invitation(UUID,TEXT,TIMESTAMPTZ)
  TO service_role;
GRANT EXECUTE ON FUNCTION revoke_organization_membership_invitation(UUID,UUID,UUID,TIMESTAMPTZ)
  TO service_role;
