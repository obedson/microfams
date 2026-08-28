-- Fail closed for suspended organizations and unresolved tenant ownership.

CREATE OR REPLACE FUNCTION has_active_organization_membership(p_organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM organization_memberships AS membership
    JOIN organizations AS organization
      ON organization.id = membership.organization_id
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
      AND organization.status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION has_active_organization_membership(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION has_active_organization_membership(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION provision_personal_organization() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_domain_tenant_ownership() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_wallet_transaction_tenant() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'properties',
    'groups',
    'farm_records',
    'user_wallets',
    'wallet_transactions',
    'withdrawal_requests',
    'contribution_cycles',
    'member_contributions',
    'payment_receipts',
    'refunds',
    'audit_logs'
  ] LOOP
    IF to_regclass('public.' || table_name) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
      EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', table_name);
      EXECUTE format(
        'CREATE POLICY tenant_read ON %I FOR SELECT USING (has_active_organization_membership(organization_id))',
        table_name
      );
    END IF;
  END LOOP;
END $$;
