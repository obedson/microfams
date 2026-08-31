BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000004101', 'membership-owner@example.test', 'not-a-real-password', 'Membership Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000004102', 'membership-invitee@example.test', 'not-a-real-password', 'Membership Invitee', 'farmer'),
  ('00000000-0000-4000-8000-000000004103', 'membership-outsider@example.test', 'not-a-real-password', 'Membership Outsider', 'farmer');

INSERT INTO organizations(
  id, name, slug, type, created_by
) VALUES (
  '00000000-0000-4000-8000-000000004110',
  'Membership Test Cooperative',
  'membership-test-cooperative',
  'cooperative',
  '00000000-0000-4000-8000-000000004101'
);
INSERT INTO organization_memberships(
  organization_id, user_id, role, status, joined_at
) VALUES (
  '00000000-0000-4000-8000-000000004110',
  '00000000-0000-4000-8000-000000004101',
  'owner', 'active', NOW()
);

DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'create_organization_membership_invitation(uuid,uuid,text,text,text[],text,timestamp with time zone,uuid,timestamp with time zone)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'accept_organization_membership_invitation(uuid,text,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'browser clients can execute organization invitation commands';
  END IF;

  IF has_table_privilege('service_role', 'organization_invitations', 'INSERT')
     OR has_table_privilege('service_role', 'organization_invitations', 'UPDATE')
     OR has_table_privilege('service_role', 'organization_memberships', 'INSERT')
     OR has_table_privilege('service_role', 'organization_memberships', 'UPDATE')
  THEN
    RAISE EXCEPTION 'service role retains direct organization membership mutation access';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT create_organization_membership_invitation(
  '00000000-0000-4000-8000-000000004110',
  '00000000-0000-4000-8000-000000004101',
  ' Membership-Invitee@Example.Test ',
  'member',
  ARRAY['groups.membership.manage'],
  repeat('d', 64),
  NOW() + INTERVAL '1 day',
  '00000000-0000-4000-8000-000000004120',
  NOW()
);
RESET ROLE;

DO $$
DECLARE
  invitation_id UUID;
BEGIN
  SELECT id INTO invitation_id
  FROM organization_invitations
  WHERE organization_id = '00000000-0000-4000-8000-000000004110'
    AND token_hash = repeat('d', 64)
    AND email = 'membership-invitee@example.test'
    AND status = 'pending';

  IF invitation_id IS NULL THEN
    RAISE EXCEPTION 'organization invitation was not normalized and persisted';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_audit_log
    WHERE organization_id = '00000000-0000-4000-8000-000000004110'
      AND action = 'organization.invitation.created'
      AND resource_id = invitation_id::TEXT
  ) THEN
    RAISE EXCEPTION 'organization invitation creation was not audited';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT create_organization_membership_invitation(
  '00000000-0000-4000-8000-000000004110',
  '00000000-0000-4000-8000-000000004101',
  'membership-invitee@example.test',
  'member',
  ARRAY['groups.membership.manage'],
  repeat('e', 64),
  NOW() + INTERVAL '1 day',
  '00000000-0000-4000-8000-000000004120',
  NOW()
);
RESET ROLE;

DO $$
BEGIN
  IF (
    SELECT count(*) FROM organization_invitations
    WHERE organization_id = '00000000-0000-4000-8000-000000004110'
      AND email = 'membership-invitee@example.test'
  ) <> 1 THEN
    RAISE EXCEPTION 'idempotent invitation replay created a duplicate';
  END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM accept_organization_membership_invitation(
      '00000000-0000-4000-8000-000000004103',
      repeat('d', 64),
      NOW()
    );
    RAISE EXCEPTION 'invitation accepted by an account with the wrong email';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_INVITATION_NOT_FOUND%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT accept_organization_membership_invitation(
  '00000000-0000-4000-8000-000000004102',
  repeat('d', 64),
  NOW()
);
SELECT accept_organization_membership_invitation(
  '00000000-0000-4000-8000-000000004102',
  repeat('d', 64),
  NOW()
);
RESET ROLE;

DO $$
DECLARE
  membership_id UUID;
BEGIN
  SELECT id INTO membership_id
  FROM organization_memberships
  WHERE organization_id = '00000000-0000-4000-8000-000000004110'
    AND user_id = '00000000-0000-4000-8000-000000004102'
    AND role = 'member'
    AND status = 'active'
    AND permissions = ARRAY['groups.membership.manage'];

  IF membership_id IS NULL THEN
    RAISE EXCEPTION 'invitation acceptance did not create the membership';
  END IF;
  IF (
    SELECT count(*) FROM organization_memberships
    WHERE organization_id = '00000000-0000-4000-8000-000000004110'
      AND user_id = '00000000-0000-4000-8000-000000004102'
  ) <> 1 THEN
    RAISE EXCEPTION 'invitation replay created a duplicate membership';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_audit_log
    WHERE organization_id = '00000000-0000-4000-8000-000000004110'
      AND action = 'organization.invitation.accepted'
      AND resource_id = membership_id::TEXT
  ) THEN
    RAISE EXCEPTION 'invitation acceptance was not audited';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT create_organization_membership_invitation(
  '00000000-0000-4000-8000-000000004110',
  '00000000-0000-4000-8000-000000004101',
  'membership-outsider@example.test',
  'viewer',
  ARRAY[]::TEXT[],
  repeat('f', 64),
  NOW() + INTERVAL '1 day',
  '00000000-0000-4000-8000-000000004121',
  NOW()
);
RESET ROLE;
DO $$
DECLARE
  invitation_id UUID;
BEGIN
  SELECT id INTO invitation_id
  FROM organization_invitations
  WHERE token_hash = repeat('f', 64);

  BEGIN
    PERFORM revoke_organization_membership_invitation(
      '00000000-0000-4000-8000-000000004110',
      '00000000-0000-4000-8000-000000004103',
      invitation_id,
      NOW()
    );
    RAISE EXCEPTION 'cross-tenant actor revoked an organization invitation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_MEMBERSHIP_PERMISSION_DENIED%' THEN RAISE; END IF;
  END;

  PERFORM revoke_organization_membership_invitation(
    '00000000-0000-4000-8000-000000004110',
    '00000000-0000-4000-8000-000000004101',
    invitation_id,
    NOW()
  );
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_invitations
    WHERE token_hash = repeat('f', 64)
      AND status = 'revoked'
      AND revoked_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'organization invitation was not revoked';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_audit_log
    WHERE organization_id = '00000000-0000-4000-8000-000000004110'
      AND action = 'organization.invitation.revoked'
  ) THEN
    RAISE EXCEPTION 'organization invitation revocation was not audited';
  END IF;
END $$;

SELECT 'organization membership invitation schema tests passed' AS result;
ROLLBACK;
