BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000003901', 'organization-owner-a@example.test', 'not-a-real-password', 'Organization Owner A', 'farmer'),
  ('00000000-0000-4000-8000-000000003902', 'organization-owner-b@example.test', 'not-a-real-password', 'Organization Owner B', 'farmer');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM organizations
    WHERE id = '00000000-0000-4000-8000-000000003901'
      AND created_by = '00000000-0000-4000-8000-000000003901'
      AND slug = 'legacy-00000000000040008000000000003901'
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'first legacy user did not receive an isolated personal organization';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM organizations
    WHERE id = '00000000-0000-4000-8000-000000003902'
      AND created_by = '00000000-0000-4000-8000-000000003902'
      AND slug = 'legacy-00000000000040008000000000003902'
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'second legacy user did not receive an isolated personal organization';
  END IF;

  IF (
    SELECT count(DISTINCT organization_id)
    FROM organization_memberships
    WHERE user_id IN (
      '00000000-0000-4000-8000-000000003901',
      '00000000-0000-4000-8000-000000003902'
    )
      AND organization_id = user_id
      AND role = 'owner'
      AND status = 'active'
  ) <> 2 THEN
    RAISE EXCEPTION 'legacy users were not provisioned into distinct owner memberships';
  END IF;
END $$;

DO $$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'organizations',
    'organization_branding',
    'organization_memberships',
    'organization_invitations',
    'organization_audit_log'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_class
      WHERE oid = to_regclass('public.' || table_name)
        AND relrowsecurity
    ) THEN
      RAISE EXCEPTION 'row level security is not enabled for %', table_name;
    END IF;
    IF has_table_privilege('anon', table_name, 'SELECT')
       OR has_table_privilege('authenticated', table_name, 'SELECT') THEN
      RAISE EXCEPTION 'browser client retains direct read access to %', table_name;
    END IF;
  END LOOP;

  IF has_function_privilege(
    'authenticated',
    'create_organization(uuid,text,text,text,text,text,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated clients can execute create_organization directly';
  END IF;
  IF NOT has_function_privilege(
    'service_role',
    'create_organization(uuid,text,text,text,text,text,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'trusted backend cannot execute create_organization';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns AS catalog_column
    WHERE catalog_column.table_schema = 'public'
      AND catalog_column.table_name = 'organization_invitations'
      AND catalog_column.column_name IN ('token', 'invitation_token', 'raw_token')
  ) THEN
    RAISE EXCEPTION 'organization invitations expose a raw token column';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT create_organization(
  '00000000-0000-4000-8000-000000003901',
  ' Schema Cooperative ',
  ' Schema Cooperative Limited ',
  ' Schema-Cooperative ',
  'cooperative',
  'ng',
  'ngn',
  'Africa/Lagos'
);
RESET ROLE;

DO $$
DECLARE
  created_id UUID;
BEGIN
  SELECT id INTO created_id
  FROM organizations
  WHERE slug = 'schema-cooperative';

  IF created_id IS NULL THEN
    RAISE EXCEPTION 'organization creation returned no persisted organization';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM organizations
    WHERE id = created_id
      AND name = 'Schema Cooperative'
      AND legal_name = 'Schema Cooperative Limited'
      AND slug = 'schema-cooperative'
      AND type = 'cooperative'
      AND jurisdiction = 'NG'
      AND default_currency = 'NGN'
      AND status = 'active'
      AND created_by = '00000000-0000-4000-8000-000000003901'
  ) THEN
    RAISE EXCEPTION 'organization creation did not normalize and persist the organization';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM organization_memberships
    WHERE organization_id = created_id
      AND user_id = '00000000-0000-4000-8000-000000003901'
      AND role = 'owner'
      AND status = 'active'
      AND joined_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'organization creation did not atomically create the owner membership';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM organization_audit_log
    WHERE organization_id = created_id
      AND actor_id = '00000000-0000-4000-8000-000000003901'
      AND action = 'organization.created'
      AND resource_type = 'organization'
      AND resource_id = created_id::TEXT
  ) THEN
    RAISE EXCEPTION 'organization creation did not write audit evidence';
  END IF;

  INSERT INTO organization_invitations(
    organization_id, email, role, token_hash, invited_by, expires_at
  ) VALUES (
    created_id, 'Invitee@Example.Test', 'member', repeat('a', 64),
    '00000000-0000-4000-8000-000000003901', NOW() + INTERVAL '1 day'
  );

  BEGIN
    INSERT INTO organization_invitations(
      organization_id, email, role, token_hash, invited_by, expires_at
    ) VALUES (
      created_id, 'invitee@example.test', 'viewer', repeat('b', 64),
      '00000000-0000-4000-8000-000000003901', NOW() + INTERVAL '1 day'
    );
    RAISE EXCEPTION 'duplicate pending invitation was accepted case-insensitively';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO organization_invitations(
      organization_id, email, role, token_hash, invited_by, expires_at
    ) VALUES (
      created_id, 'other@example.test', 'viewer', repeat('a', 64),
      '00000000-0000-4000-8000-000000003901', NOW() + INTERVAL '1 day'
    );
    RAISE EXCEPTION 'duplicate invitation token hash was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO organization_invitations(
      organization_id, email, role, token_hash, invited_by, expires_at
    ) VALUES (
      created_id, 'expired@example.test', 'viewer', repeat('c', 64),
      '00000000-0000-4000-8000-000000003901', NOW() - INTERVAL '1 day'
    );
    RAISE EXCEPTION 'already-expired invitation was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE organizations SET status = 'deleted' WHERE id = created_id;
    RAISE EXCEPTION 'invalid organization lifecycle state was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO organization_memberships(organization_id, user_id, role)
    VALUES (created_id, '00000000-0000-4000-8000-000000003902', 'platform_admin');
    RAISE EXCEPTION 'invalid tenant role was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

DO $$
BEGIN
  BEGIN
    PERFORM create_organization(
      '00000000-0000-4000-8000-000000003999',
      'Missing Owner Organization',
      NULL,
      'missing-owner-organization',
      'ngo',
      'NG',
      'NGN',
      'Africa/Lagos'
    );
    RAISE EXCEPTION 'organization creation accepted a missing owner';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%owner does not exist%' THEN RAISE; END IF;
  END;

  IF EXISTS (
    SELECT 1 FROM organizations WHERE slug = 'missing-owner-organization'
  ) THEN
    RAISE EXCEPTION 'failed organization creation left partial organization state';
  END IF;
END $$;

SELECT 'organization foundation schema tests passed' AS result;
ROLLBACK;
