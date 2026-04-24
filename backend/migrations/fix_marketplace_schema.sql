-- Add missing columns to marketplace_products table
ALTER TABLE marketplace_products 
ADD COLUMN IF NOT EXISTS unit VARCHAR(50) DEFAULT 'kg',
ADD COLUMN IF NOT EXISTS minimum_order INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS location VARCHAR(255),
ADD COLUMN IF NOT EXISTS images JSONB DEFAULT '[]';

-- Migrate existing image_url to images array
UPDATE marketplace_products 
SET images = CASE 
  WHEN image_url IS NOT NULL THEN jsonb_build_array(image_url)
  ELSE '[]'::jsonb
END
WHERE images = '[]'::jsonb OR images IS NULL;

-- Rename seller_id to supplier_id for consistency
ALTER TABLE marketplace_products 
RENAME COLUMN seller_id TO supplier_id;

-- Rename stock to stock_quantity for consistency
ALTER TABLE marketplace_products 
RENAME COLUMN stock TO stock_quantity;

-- Update foreign key constraint name if needed
ALTER TABLE marketplace_products 
DROP CONSTRAINT IF EXISTS marketplace_products_seller_id_fkey;

ALTER TABLE marketplace_products 
ADD CONSTRAINT marketplace_products_supplier_id_fkey 
FOREIGN KEY (supplier_id) REFERENCES users(id) ON DELETE CASCADE;

-- Verify the changes
SELECT column_name, data_type, column_default 
FROM information_schema.columns 
WHERE table_name = 'marketplace_products'
ORDER BY ordinal_position;
