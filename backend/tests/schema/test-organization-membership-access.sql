BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000005101', 'access-owner@example.test', 'not-a-real-password', 'Access Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000005102', 'access-member@example.test', 'not-a-real-password', 'Access Member', 'farmer'),
  ('00000000-0000-4000-8000-000000005103', 'access-admin@example.test', 'not-a-real-password', 'Access Admin', 'farmer');

INSERT INTO organizations(id, name, slug, type, created_by) VALUES (
  '00000000-0000-4000-8000-000000005110',
  'Access Test Cooperative',
  'access-test-cooperative',
  'cooperative',
  '00000000-0000-4000-8000-000000005101'
);

INSERT INTO organization_memberships(
  id, organization_id, user_id, role, permissions, status, joined_at
) VALUES
  (
    '00000000-0000-4000-8000-000000005120',
    '00000000-0000-4000-8000-000000005110',
    '00000000-0000-4000-8000-000000005101',
    'owner', '{}', 'active', NOW()
  ),
  (
    '00000000-0000-4000-8000-000000005121',
    '00000000-0000-4000-8000-000000005110',
    '00000000-0000-4000-8000-000000005102',
    'member', ARRAY['groups.read'], 'active', NOW()
  ),
  (
    '00000000-0000-4000-8000-000000005122',
    '00000000-0000-4000-8000-000000005110',
    '00000000-0000-4000-8000-000000005103',
    'admin', '{}', 'active', NOW()
  );

DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'update_organization_membership_access(uuid,uuid,uuid,text,text[],timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'browser clients can execute membership access commands';
  END IF;
  IF has_table_privilege('service_role', 'organization_memberships', 'UPDATE') THEN
    RAISE EXCEPTION 'service role retains direct membership update access';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT update_organization_membership_access(
  '00000000-0000-4000-8000-000000005110',
  '00000000-0000-4000-8000-000000005101',
  '00000000-0000-4000-8000-000000005121',
  'finance_manager',
  ARRAY['groups.read', 'financial.*', 'groups.read'],
  NOW()
);
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE id = '00000000-0000-4000-8000-000000005121'
      AND organization_id = '00000000-0000-4000-8000-000000005110'
      AND role = 'finance_manager'
      AND permissions = ARRAY['financial.*', 'groups.read']
  ) THEN
    RAISE EXCEPTION 'membership access was not normalized and updated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM organization_audit_log
    WHERE organization_id = '00000000-0000-4000-8000-000000005110'
      AND actor_id = '00000000-0000-4000-8000-000000005101'
      AND action = 'organization.membership.access_updated'
      AND resource_id = '00000000-0000-4000-8000-000000005121'
      AND before_value->>'role' = 'member'
      AND after_value->>'role' = 'finance_manager'
  ) THEN
    RAISE EXCEPTION 'membership access update was not audited';
  END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM update_organization_membership_access(
      '00000000-0000-4000-8000-000000005110',
      '00000000-0000-4000-8000-000000005103',
      '00000000-0000-4000-8000-000000005121',
      'viewer',
      '{}'::TEXT[],
      NOW()
    );
    RAISE EXCEPTION 'administrator changed membership access';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_MEMBERSHIP_PERMISSION_DENIED%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM update_organization_membership_access(
      '00000000-0000-4000-8000-000000005110',
      '00000000-0000-4000-8000-000000005101',
      '00000000-0000-4000-8000-000000005120',
      'admin',
      '{}'::TEXT[],
      NOW()
    );
    RAISE EXCEPTION 'generic access command changed an owner';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_OWNERSHIP_WORKFLOW_REQUIRED%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM update_organization_membership_access(
      '00000000-0000-4000-8000-000000005110',
      '00000000-0000-4000-8000-000000005101',
      '00000000-0000-4000-8000-000000005999',
      'viewer',
      '{}'::TEXT[],
      NOW()
    );
    RAISE EXCEPTION 'cross-tenant membership identifier was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_MEMBERSHIP_NOT_FOUND%' THEN
      RAISE;
    END IF;
  END;
END $$;
RESET ROLE;

SELECT 'organization membership access schema tests passed' AS result;
ROLLBACK;
