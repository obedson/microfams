-- Add integration columns to groups
ALTER TABLE groups ADD COLUMN IF NOT EXISTS group_fund_balance DECIMAL(12,2) DEFAULT 0;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS group_booking_discount DECIMAL(5,2) DEFAULT 5;

-- Add integration columns to marketplace_products
ALTER TABLE marketplace_products ADD COLUMN IF NOT EXISTS bulk_discount_rate DECIMAL(5,2) DEFAULT 0;
ALTER TABLE marketplace_products ADD COLUMN IF NOT EXISTS minimum_bulk_quantity INTEGER DEFAULT 10;

-- Add integration columns to farm_records
ALTER TABLE farm_records ADD COLUMN IF NOT EXISTS booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL;

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_groups_fund_balance ON groups(group_fund_balance);
CREATE INDEX IF NOT EXISTS idx_marketplace_products_bulk ON marketplace_products(bulk_discount_rate) WHERE bulk_discount_rate > 0;
CREATE INDEX IF NOT EXISTS idx_farm_records_booking ON farm_records(booking_id);
