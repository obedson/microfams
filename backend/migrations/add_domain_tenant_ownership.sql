-- Tenant ownership for operational domain records.
-- Cross-organization transactions retain both participating organizations.

ALTER TABLE properties ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS provider_organization_id UUID REFERENCES organizations(id);
ALTER TABLE groups ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE farm_records ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE marketplace_products ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE orders ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE orders ADD COLUMN IF NOT EXISTS supplier_organization_id UUID REFERENCES organizations(id);
ALTER TABLE courses ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE user_wallets ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE wallet_transactions ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE contribution_cycles ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE member_contributions ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE refunds ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);

-- Preserve ownerless legacy rows without leaking them into an active tenant.
-- This suspended system organization has no membership and therefore cannot be
-- selected through the tenant resolver or read through tenant RLS policies.
INSERT INTO organizations(
  id, name, slug, type, status, metadata
) VALUES (
  '00000000-0000-4000-8000-000000000900',
  'Legacy Ownership Quarantine',
  'system-unassigned-legacy',
  'farm_business',
  'suspended',
  '{"system": true, "purpose": "unresolved_legacy_ownership"}'::JSONB
)
ON CONFLICT (id) DO NOTHING;

-- Existing users each own a personal organization whose id equals their user id.
UPDATE properties SET organization_id = owner_id WHERE organization_id IS NULL;
UPDATE groups SET organization_id = creator_id WHERE organization_id IS NULL;
UPDATE farm_records SET organization_id = farmer_id WHERE organization_id IS NULL;
UPDATE user_wallets SET organization_id = user_id WHERE organization_id IS NULL;

UPDATE bookings b
SET organization_id = b.farmer_id,
    provider_organization_id = p.organization_id
FROM properties p
WHERE b.property_id = p.id
  AND (b.organization_id IS NULL OR b.provider_organization_id IS NULL);

UPDATE marketplace_products
SET organization_id = supplier_id
WHERE organization_id IS NULL AND supplier_id IS NOT NULL;

UPDATE orders o
SET organization_id = o.buyer_id,
    supplier_organization_id = p.organization_id
FROM marketplace_products p
WHERE o.product_id = p.id
  AND (o.organization_id IS NULL OR o.supplier_organization_id IS NULL);

UPDATE contribution_cycles c
SET organization_id = g.organization_id
FROM groups g
WHERE c.group_id = g.id AND c.organization_id IS NULL;

UPDATE member_contributions mc
SET organization_id = c.organization_id
FROM contribution_cycles c
WHERE mc.cycle_id = c.id AND mc.organization_id IS NULL;

UPDATE wallet_transactions wt
SET organization_id = uw.organization_id
FROM user_wallets uw
WHERE wt.wallet_id = uw.id AND wt.organization_id IS NULL;

UPDATE wallet_transactions wt
SET organization_id = g.organization_id
FROM groups g
WHERE wt.group_id = g.id AND wt.organization_id IS NULL;

UPDATE payment_receipts r
SET organization_id = b.organization_id
FROM bookings b
WHERE r.booking_id = b.id AND r.organization_id IS NULL;

UPDATE refunds r
SET organization_id = b.organization_id
FROM bookings b
WHERE r.booking_id = b.id AND r.organization_id IS NULL;

-- Any row still unresolved after following its ownership chain is malformed
-- legacy data. Quarantine rather than deleting it or assigning it to a user.
UPDATE properties SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE bookings
SET organization_id = COALESCE(organization_id, '00000000-0000-4000-8000-000000000900'),
    provider_organization_id = COALESCE(provider_organization_id, '00000000-0000-4000-8000-000000000900')
WHERE organization_id IS NULL OR provider_organization_id IS NULL;
UPDATE groups SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE farm_records SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE orders SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE user_wallets SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE wallet_transactions SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE contribution_cycles SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE member_contributions SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE payment_receipts SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;
UPDATE refunds SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;

INSERT INTO organization_audit_log(
  organization_id, action, resource_type, resource_id, after_value
)
SELECT
  '00000000-0000-4000-8000-000000000900',
  'migration.legacy_ownership_quarantined',
  'database_migration',
  'add_domain_tenant_ownership',
  jsonb_build_object(
    'properties', (SELECT count(*) FROM properties WHERE organization_id = '00000000-0000-4000-8000-000000000900'),
    'bookings', (SELECT count(*) FROM bookings WHERE organization_id = '00000000-0000-4000-8000-000000000900' OR provider_organization_id = '00000000-0000-4000-8000-000000000900'),
    'groups', (SELECT count(*) FROM groups WHERE organization_id = '00000000-0000-4000-8000-000000000900'),
    'farm_records', (SELECT count(*) FROM farm_records WHERE organization_id = '00000000-0000-4000-8000-000000000900'),
    'orders', (SELECT count(*) FROM orders WHERE organization_id = '00000000-0000-4000-8000-000000000900'),
    'wallet_transactions', (SELECT count(*) FROM wallet_transactions WHERE organization_id = '00000000-0000-4000-8000-000000000900')
  )
WHERE EXISTS (
  SELECT 1 FROM bookings
  WHERE organization_id = '00000000-0000-4000-8000-000000000900'
     OR provider_organization_id = '00000000-0000-4000-8000-000000000900'
  UNION ALL SELECT 1 FROM properties WHERE organization_id = '00000000-0000-4000-8000-000000000900'
  UNION ALL SELECT 1 FROM groups WHERE organization_id = '00000000-0000-4000-8000-000000000900'
  UNION ALL SELECT 1 FROM farm_records WHERE organization_id = '00000000-0000-4000-8000-000000000900'
  UNION ALL SELECT 1 FROM orders WHERE organization_id = '00000000-0000-4000-8000-000000000900'
  UNION ALL SELECT 1 FROM wallet_transactions WHERE organization_id = '00000000-0000-4000-8000-000000000900'
);

ALTER TABLE properties ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE bookings ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE bookings ALTER COLUMN provider_organization_id SET NOT NULL;
ALTER TABLE groups ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE farm_records ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE orders ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE user_wallets ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE wallet_transactions ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE contribution_cycles ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE member_contributions ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE payment_receipts ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE refunds ALTER COLUMN organization_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_properties_organization ON properties(organization_id);
CREATE INDEX IF NOT EXISTS idx_bookings_customer_organization ON bookings(organization_id);
CREATE INDEX IF NOT EXISTS idx_bookings_provider_organization ON bookings(provider_organization_id);
CREATE INDEX IF NOT EXISTS idx_groups_organization ON groups(organization_id);
CREATE INDEX IF NOT EXISTS idx_farm_records_organization ON farm_records(organization_id);
CREATE INDEX IF NOT EXISTS idx_marketplace_products_organization ON marketplace_products(organization_id);
CREATE INDEX IF NOT EXISTS idx_orders_buyer_organization ON orders(organization_id);
CREATE INDEX IF NOT EXISTS idx_orders_supplier_organization ON orders(supplier_organization_id);
CREATE INDEX IF NOT EXISTS idx_courses_organization ON courses(organization_id);
CREATE INDEX IF NOT EXISTS idx_user_wallets_organization ON user_wallets(organization_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_organization ON wallet_transactions(organization_id);
CREATE INDEX IF NOT EXISTS idx_contribution_cycles_organization ON contribution_cycles(organization_id);
CREATE INDEX IF NOT EXISTS idx_member_contributions_organization ON member_contributions(organization_id);

CREATE OR REPLACE FUNCTION has_active_organization_membership(p_organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = auth.uid()
      AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION has_active_organization_membership(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION has_active_organization_membership(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION enforce_domain_tenant_ownership() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_related_organization UUID;
  v_actor_id UUID;
  v_row JSONB;
BEGIN
  v_row := to_jsonb(NEW);
  IF TG_TABLE_NAME = 'properties' THEN
    v_actor_id := (v_row->>'owner_id')::UUID;
    NEW.organization_id := COALESCE(NEW.organization_id, v_actor_id);
    IF NOT EXISTS (
      SELECT 1 FROM organization_memberships
      WHERE organization_id = NEW.organization_id AND user_id = v_actor_id AND status = 'active'
    ) THEN RAISE EXCEPTION 'Property owner is not an active organization member'; END IF;
  ELSIF TG_TABLE_NAME = 'bookings' THEN
    v_actor_id := (v_row->>'farmer_id')::UUID;
    NEW.organization_id := COALESCE(NEW.organization_id, v_actor_id);
    SELECT organization_id INTO v_related_organization
    FROM properties WHERE id = (v_row->>'property_id')::UUID;
    IF v_related_organization IS NULL THEN RAISE EXCEPTION 'Booking property has no organization'; END IF;
    NEW := jsonb_populate_record(NEW, jsonb_build_object('provider_organization_id', v_related_organization));
    IF NOT EXISTS (
      SELECT 1 FROM organization_memberships
      WHERE organization_id = NEW.organization_id AND user_id = v_actor_id AND status = 'active'
    ) THEN RAISE EXCEPTION 'Booking farmer is not an active customer organization member'; END IF;
  ELSIF TG_TABLE_NAME = 'groups' THEN
    NEW.organization_id := COALESCE(NEW.organization_id, (v_row->>'creator_id')::UUID);
  ELSIF TG_TABLE_NAME = 'farm_records' THEN
    NEW.organization_id := COALESCE(NEW.organization_id, (v_row->>'farmer_id')::UUID);
  ELSIF TG_TABLE_NAME = 'marketplace_products' AND v_row->>'supplier_id' IS NOT NULL THEN
    NEW.organization_id := COALESCE(NEW.organization_id, (v_row->>'supplier_id')::UUID);
  ELSIF TG_TABLE_NAME = 'orders' THEN
    NEW.organization_id := COALESCE(NEW.organization_id, (v_row->>'buyer_id')::UUID);
    SELECT organization_id INTO v_related_organization
    FROM marketplace_products WHERE id = (v_row->>'product_id')::UUID;
    NEW := jsonb_populate_record(NEW, jsonb_build_object('supplier_organization_id', v_related_organization));
  ELSIF TG_TABLE_NAME = 'user_wallets' THEN
    NEW.organization_id := COALESCE(NEW.organization_id, (v_row->>'user_id')::UUID);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_wallet_transaction_tenant() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.wallet_id IS NOT NULL THEN
    SELECT organization_id INTO NEW.organization_id
    FROM user_wallets WHERE id = NEW.wallet_id;
  ELSIF NEW.group_id IS NOT NULL THEN
    SELECT organization_id INTO NEW.organization_id
    FROM groups WHERE id = NEW.group_id;
  END IF;

  IF NEW.organization_id IS NULL THEN
    RAISE EXCEPTION 'Wallet transaction has no organization owner';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_wallet_transaction_tenant ON wallet_transactions;
CREATE TRIGGER enforce_wallet_transaction_tenant
BEFORE INSERT OR UPDATE OF wallet_id, group_id ON wallet_transactions
FOR EACH ROW EXECUTE FUNCTION enforce_wallet_transaction_tenant();

DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'properties','bookings','groups','farm_records','marketplace_products','orders','user_wallets'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS enforce_tenant_ownership ON %I', table_name);
    EXECUTE format(
      'CREATE TRIGGER enforce_tenant_ownership BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION enforce_domain_tenant_ownership()',
      table_name
    );
  END LOOP;
END $$;

DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'properties','groups','farm_records','marketplace_products','courses','user_wallets',
    'wallet_transactions','contribution_cycles','member_contributions','payment_receipts','refunds','audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT USING (organization_id IS NULL OR has_active_organization_membership(organization_id))',
      table_name
    );
  END LOOP;
END $$;

ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_read ON bookings;
CREATE POLICY tenant_read ON bookings FOR SELECT USING (
  has_active_organization_membership(organization_id)
  OR has_active_organization_membership(provider_organization_id)
);

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_read ON orders;
CREATE POLICY tenant_read ON orders FOR SELECT USING (
  has_active_organization_membership(organization_id)
  OR has_active_organization_membership(supplier_organization_id)
);
