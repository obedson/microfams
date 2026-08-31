BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000004201', 'settings-owner@example.test', 'not-a-real-password', 'Settings Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000004202', 'settings-admin@example.test', 'not-a-real-password', 'Settings Admin', 'farmer'),
  ('00000000-0000-4000-8000-000000004203', 'settings-outsider@example.test', 'not-a-real-password', 'Settings Outsider', 'farmer');

INSERT INTO organizations(id, name, slug, type, created_by) VALUES (
  '00000000-0000-4000-8000-000000004210',
  'Settings Test Cooperative', 'settings-test-cooperative', 'cooperative',
  '00000000-0000-4000-8000-000000004201'
);
INSERT INTO organization_memberships(
  organization_id, user_id, role, status, joined_at
) VALUES
  ('00000000-0000-4000-8000-000000004210', '00000000-0000-4000-8000-000000004201', 'owner', 'active', NOW()),
  ('00000000-0000-4000-8000-000000004210', '00000000-0000-4000-8000-000000004202', 'admin', 'active', NOW());

DO $$
BEGIN
  IF has_table_privilege('service_role', 'organization_settings', 'INSERT')
     OR has_table_privilege('service_role', 'organization_settings', 'UPDATE')
     OR has_table_privilege('service_role', 'organization_settings', 'DELETE')
  THEN
    RAISE EXCEPTION 'service role retains direct organization settings mutation access';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'update_organization_settings(uuid,uuid,jsonb,jsonb,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'browser clients can execute organization settings commands';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT update_organization_settings(
  '00000000-0000-4000-8000-000000004210',
  '00000000-0000-4000-8000-000000004201',
  '{"email":true,"sms":false}'::JSONB,
  '{"exportsEnabled":false,"crossTenantReporting":false}'::JSONB,
  NOW()
);
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_settings
    WHERE organization_id = '00000000-0000-4000-8000-000000004210'
      AND notification_preferences = '{"email":true,"sms":false}'::JSONB
      AND reporting_policy = '{"exportsEnabled":false,"crossTenantReporting":false}'::JSONB
      AND updated_by = '00000000-0000-4000-8000-000000004201'
  ) THEN
    RAISE EXCEPTION 'owner settings update was not persisted';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_audit_log
    WHERE organization_id = '00000000-0000-4000-8000-000000004210'
      AND actor_id = '00000000-0000-4000-8000-000000004201'
      AND action = 'organization.settings.updated'
      AND after_value->'notificationPreferences' = '{"email":true,"sms":false}'::JSONB
  ) THEN
    RAISE EXCEPTION 'organization settings update was not audited';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT update_organization_settings(
  '00000000-0000-4000-8000-000000004210',
  '00000000-0000-4000-8000-000000004202',
  NULL,
  '{"exportsEnabled":true,"crossTenantReporting":false}'::JSONB,
  NOW()
);
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_settings
    WHERE organization_id = '00000000-0000-4000-8000-000000004210'
      AND notification_preferences = '{"email":true,"sms":false}'::JSONB
      AND reporting_policy = '{"exportsEnabled":true,"crossTenantReporting":false}'::JSONB
      AND updated_by = '00000000-0000-4000-8000-000000004202'
  ) THEN
    RAISE EXCEPTION 'admin partial settings update did not preserve notification preferences';
  END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM update_organization_settings(
      '00000000-0000-4000-8000-000000004210',
      '00000000-0000-4000-8000-000000004203',
      '{"email":false}'::JSONB, NULL, NOW()
    );
    RAISE EXCEPTION 'cross-tenant actor updated organization settings';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORGANIZATION_MEMBERSHIP_PERMISSION_DENIED%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'organization_settings'::regclass AND relrowsecurity
  ) THEN
    RAISE EXCEPTION 'organization settings row level security is not enabled';
  END IF;
END $$;

SELECT 'organization settings schema tests passed' AS result;
ROLLBACK;
