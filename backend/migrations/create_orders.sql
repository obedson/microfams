-- Create orders table
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  items JSONB NOT NULL,
  total DECIMAL(10, 2) NOT NULL,
  delivery_info JSONB NOT NULL,
  status VARCHAR(50) DEFAULT 'pending',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Add foreign key constraint separately
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'orders_user_id_fkey'
  ) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_user_id_fkey 
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
  END IF;
END $$;

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
