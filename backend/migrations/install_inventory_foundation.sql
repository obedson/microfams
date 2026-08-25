-- Tenant-scoped inventory foundation for WP-P6-002.
CREATE TABLE IF NOT EXISTS inventory_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  sku TEXT,
  unit TEXT NOT NULL CHECK (length(trim(unit)) > 0),
  quantity_minor BIGINT NOT NULL DEFAULT 0 CHECK (quantity_minor >= 0),
  reorder_level_minor BIGINT NOT NULL DEFAULT 0 CHECK (reorder_level_minor >= 0),
  metadata JSONB NOT NULL DEFAULT ''{}''::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, sku)
);
CREATE TABLE IF NOT EXISTS inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  item_id UUID NOT NULL REFERENCES inventory_items(id),
  quantity_minor BIGINT NOT NULL CHECK (quantity_minor <> 0),
  reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  idempotency_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_inventory_items_org ON inventory_items(organization_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_item ON inventory_movements(organization_id, item_id);
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;
