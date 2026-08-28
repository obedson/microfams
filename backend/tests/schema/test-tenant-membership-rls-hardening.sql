BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000003101', 'tenant-a@example.test', 'not-a-real-password', 'Tenant A Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000003102', 'tenant-b@example.test', 'not-a-real-password', 'Tenant B Owner', 'farmer');

INSERT INTO properties(
  id, owner_id, title, description, livestock_type, space_type, size, size_unit,
  city, lga, price_per_month, available_from, available_to
) VALUES (
  '00000000-0000-4000-8000-000000003111',
  '00000000-0000-4000-8000-000000003101',
  'Tenant A Property',
  'Tenant isolation fixture',
  'poultry',
  'empty_land',
  10,
  'm2',
  'Abuja',
  'AMAC',
  1000,
  DATE '2027-01-01',
  DATE '2027-12-31'
);

INSERT INTO audit_logs(id, action, resource_type, organization_id) VALUES (
  '00000000-0000-4000-8000-000000003121',
  'legacy.unresolved',
  'legacy_record',
  NULL
);

GRANT SELECT ON properties, audit_logs TO authenticated;

DO $$
DECLARE
  policy_expression TEXT;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM organization_memberships
    WHERE organization_id = '00000000-0000-4000-8000-000000003101'
      AND user_id = '00000000-0000-4000-8000-000000003101'
      AND role = 'owner'
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'personal organization owner membership was not provisioned';
  END IF;

  SELECT qual INTO policy_expression
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'audit_logs' AND policyname = 'tenant_read';

  IF policy_expression IS NULL
     OR policy_expression ILIKE '%organization_id IS NULL%'
     OR policy_expression NOT ILIKE '%has_active_organization_membership%' THEN
    RAISE EXCEPTION 'audit-log tenant policy is not fail closed: %', policy_expression;
  END IF;

  IF has_function_privilege('anon', 'has_active_organization_membership(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'tenant membership helper has unsafe execution grants';
  END IF;

  IF has_function_privilege('authenticated', 'provision_personal_organization()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'enforce_domain_tenant_ownership()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'enforce_wallet_transaction_tenant()', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated clients can execute trigger-only tenant functions';
  END IF;
END $$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000003101', TRUE);

DO $$
BEGIN
  IF NOT has_active_organization_membership('00000000-0000-4000-8000-000000003101') THEN
    RAISE EXCEPTION 'active owner membership was rejected';
  END IF;
  IF (SELECT count(*) FROM properties WHERE id = '00000000-0000-4000-8000-000000003111') <> 1 THEN
    RAISE EXCEPTION 'tenant owner cannot read own property';
  END IF;
  IF (SELECT count(*) FROM audit_logs WHERE id = '00000000-0000-4000-8000-000000003121') <> 0 THEN
    RAISE EXCEPTION 'null-owned audit record leaked through tenant RLS';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000003102', TRUE);

DO $$
BEGIN
  IF (SELECT count(*) FROM properties WHERE id = '00000000-0000-4000-8000-000000003111') <> 0 THEN
    RAISE EXCEPTION 'cross-tenant property read was permitted';
  END IF;
END $$;

RESET ROLE;
UPDATE organizations
SET status = 'suspended'
WHERE id = '00000000-0000-4000-8000-000000003101';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000003101', TRUE);

DO $$
BEGIN
  IF has_active_organization_membership('00000000-0000-4000-8000-000000003101') THEN
    RAISE EXCEPTION 'suspended organization still produced active membership';
  END IF;
  IF (SELECT count(*) FROM properties WHERE id = '00000000-0000-4000-8000-000000003111') <> 0 THEN
    RAISE EXCEPTION 'suspended organization retained tenant row access';
  END IF;
END $$;

RESET ROLE;
SELECT 'tenant RLS suspension hardening schema tests passed' AS result;
ROLLBACK;
