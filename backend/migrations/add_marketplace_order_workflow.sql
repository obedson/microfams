-- Atomic, tenant-owned marketplace ordering and payment state.

ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_reference TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ;

DO $$ BEGIN
  ALTER TABLE orders ADD CONSTRAINT orders_payment_status_check
    CHECK (payment_status IN ('pending', 'paid', 'failed'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_orders_payment_reference
  ON orders(payment_reference) WHERE payment_reference IS NOT NULL;

CREATE OR REPLACE FUNCTION enforce_marketplace_tenant() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_product_organization_id UUID;
BEGIN
  IF TG_TABLE_NAME = 'marketplace_products' THEN
    IF NEW.supplier_id IS NULL THEN
      IF NEW.organization_id IS NOT NULL THEN
        RAISE EXCEPTION 'Global marketplace products cannot be tenant owned without a supplier';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.organization_id IS NULL THEN
      RAISE EXCEPTION 'Marketplace product requires an organization owner';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM organization_memberships
      WHERE organization_id = NEW.organization_id
        AND user_id = NEW.supplier_id
        AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'Marketplace supplier is not an active organization member';
    END IF;
    RETURN NEW;
  END IF;

  SELECT organization_id INTO v_product_organization_id
  FROM marketplace_products WHERE id = NEW.product_id;

  IF v_product_organization_id IS NULL THEN
    RAISE EXCEPTION 'Marketplace order product has no supplier organization';
  END IF;
  IF NEW.organization_id IS NULL THEN
    RAISE EXCEPTION 'Marketplace order requires a buyer organization';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = NEW.organization_id
      AND user_id = NEW.buyer_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Marketplace buyer is not an active organization member';
  END IF;

  NEW.supplier_organization_id := v_product_organization_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_marketplace_tenant ON marketplace_products;
CREATE TRIGGER enforce_marketplace_tenant
BEFORE INSERT OR UPDATE OF supplier_id, organization_id ON marketplace_products
FOR EACH ROW EXECUTE FUNCTION enforce_marketplace_tenant();

DROP TRIGGER IF EXISTS enforce_marketplace_tenant ON orders;
CREATE TRIGGER enforce_marketplace_tenant
BEFORE INSERT OR UPDATE OF buyer_id, product_id, organization_id, supplier_organization_id ON orders
FOR EACH ROW EXECUTE FUNCTION enforce_marketplace_tenant();

CREATE OR REPLACE FUNCTION create_marketplace_order_atomic(
  p_buyer_id UUID,
  p_organization_id UUID,
  p_product_id UUID,
  p_quantity INTEGER,
  p_delivery_address TEXT,
  p_phone TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_product marketplace_products%ROWTYPE;
  v_order orders%ROWTYPE;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Order quantity must be a positive whole number';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_buyer_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Marketplace buyer has no active organization membership';
  END IF;

  SELECT * INTO v_product
  FROM marketplace_products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Marketplace product not found'; END IF;
  IF v_product.organization_id IS NULL OR v_product.supplier_id IS NULL THEN
    RAISE EXCEPTION 'Marketplace product has no supplier organization';
  END IF;
  IF p_quantity < COALESCE(v_product.minimum_order, 1) THEN
    RAISE EXCEPTION 'Order quantity is below the product minimum order';
  END IF;
  IF COALESCE(v_product.stock_quantity, 0) < p_quantity THEN
    RAISE EXCEPTION 'Insufficient marketplace product stock';
  END IF;

  UPDATE marketplace_products
  SET stock_quantity = stock_quantity - p_quantity,
      updated_at = NOW()
  WHERE id = p_product_id;

  INSERT INTO orders(
    buyer_id, organization_id, supplier_organization_id, product_id,
    quantity, unit_price, total_amount, delivery_address, phone
  ) VALUES (
    p_buyer_id, p_organization_id, v_product.organization_id, p_product_id,
    p_quantity, v_product.price, v_product.price * p_quantity,
    COALESCE(NULLIF(trim(p_delivery_address), ''), 'Not provided'),
    COALESCE(NULLIF(trim(p_phone), ''), 'Not provided')
  ) RETURNING * INTO v_order;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    p_organization_id, p_buyer_id, 'marketplace.order.created', 'marketplace_order',
    v_order.id::TEXT, jsonb_build_object(
      'product_id', p_product_id, 'quantity', p_quantity,
      'supplier_organization_id', v_product.organization_id,
      'total_amount', v_order.total_amount
    )
  );

  RETURN to_jsonb(v_order);
END;
$$;

CREATE OR REPLACE FUNCTION update_marketplace_order_status(
  p_order_id UUID,
  p_supplier_organization_id UUID,
  p_actor_id UUID,
  p_new_status TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Marketplace order not found'; END IF;
  IF v_order.supplier_organization_id <> p_supplier_organization_id THEN
    RAISE EXCEPTION 'Marketplace order does not belong to the selected supplier organization';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_supplier_organization_id
      AND user_id = p_actor_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Marketplace supplier has no active organization membership';
  END IF;
  IF p_new_status = 'confirmed' THEN
    RAISE EXCEPTION 'Marketplace orders are confirmed only by verified payment';
  END IF;
  IF NOT (
    (v_order.status = 'pending' AND p_new_status = 'cancelled') OR
    (v_order.status = 'confirmed' AND p_new_status IN ('shipped', 'cancelled')) OR
    (v_order.status = 'shipped' AND p_new_status = 'delivered')
  ) THEN
    RAISE EXCEPTION 'Invalid marketplace order status transition from % to %', v_order.status, p_new_status;
  END IF;

  UPDATE orders SET status = p_new_status, updated_at = NOW()
  WHERE id = p_order_id RETURNING * INTO v_order;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    p_supplier_organization_id, p_actor_id, 'marketplace.order.status_changed',
    'marketplace_order', p_order_id::TEXT,
    jsonb_build_object('status', p_new_status)
  );

  RETURN to_jsonb(v_order);
END;
$$;

REVOKE ALL ON FUNCTION create_marketplace_order_atomic(UUID, UUID, UUID, INTEGER, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION update_marketplace_order_status(UUID, UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_marketplace_order_atomic(UUID, UUID, UUID, INTEGER, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION update_marketplace_order_status(UUID, UUID, UUID, TEXT)
  TO service_role;
