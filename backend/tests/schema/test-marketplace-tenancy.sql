DO $$
DECLARE
  product_id UUID;
  order_data JSONB;
  order_id UUID;
  stock_after INTEGER;
BEGIN
  INSERT INTO marketplace_products(
    organization_id, supplier_id, name, description, price, category,
    stock_quantity, minimum_order, unit, location
  ) VALUES (
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101',
    'Tenant-safe poultry feed', 'Marketplace isolation fixture', 2500, 'feed',
    10, 2, 'bag', 'Abuja'
  ) RETURNING id INTO product_id;

  order_data := create_marketplace_order_atomic(
    '00000000-0000-4000-8000-000000000102',
    '00000000-0000-4000-8000-000000000102',
    product_id, 2, 'Schema Test Address', '+2348000000000'
  );
  order_id := (order_data->>'id')::UUID;

  IF order_data->>'organization_id' <> '00000000-0000-4000-8000-000000000102'
     OR order_data->>'supplier_organization_id' <> '00000000-0000-4000-8000-000000000101' THEN
    RAISE EXCEPTION 'marketplace order organization ownership is incorrect';
  END IF;

  SELECT stock_quantity INTO stock_after FROM marketplace_products WHERE id = product_id;
  IF stock_after <> 8 THEN RAISE EXCEPTION 'atomic marketplace stock decrement failed'; END IF;

  order_data := update_marketplace_order_status(
    order_id,
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101',
    'cancelled'
  );
  IF order_data->>'status' <> 'cancelled' THEN
    RAISE EXCEPTION 'supplier organization could not update its marketplace order';
  END IF;
END $$;

GRANT SELECT ON marketplace_products, orders TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM marketplace_products WHERE name = 'Tenant-safe poultry feed'
  ) OR NOT EXISTS (
    SELECT 1 FROM orders
    WHERE supplier_organization_id = '00000000-0000-4000-8000-000000000101'
  ) THEN RAISE EXCEPTION 'supplier organization cannot read its marketplace records'; END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM marketplace_products WHERE name = 'Tenant-safe poultry feed'
  ) OR NOT EXISTS (
    SELECT 1 FROM orders WHERE organization_id = '00000000-0000-4000-8000-000000000102'
  ) THEN RAISE EXCEPTION 'buyer marketplace visibility is incorrect'; END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', FALSE);
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM marketplace_products WHERE name = 'Tenant-safe poultry feed'
  ) OR EXISTS (
    SELECT 1 FROM orders
    WHERE organization_id IN (
      '00000000-0000-4000-8000-000000000101',
      '00000000-0000-4000-8000-000000000102'
    )
  ) THEN RAISE EXCEPTION 'unrelated organization can read marketplace data'; END IF;
END $$;
RESET ROLE;
