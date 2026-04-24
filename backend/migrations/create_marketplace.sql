-- Create marketplace_products table
CREATE TABLE IF NOT EXISTS marketplace_products (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  price DECIMAL(10, 2) NOT NULL,
  category VARCHAR(100),
  stock INTEGER DEFAULT 0,
  image_url TEXT,
  seller_id UUID REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample products
INSERT INTO marketplace_products (name, description, price, category, stock, image_url) VALUES
('Chicken Feed - 25kg', 'High-quality chicken feed for optimal growth', 5500, 'feed', 100, 'https://images.unsplash.com/photo-1560493676-04071c5f467b?w=400'),
('Cattle Feed - 50kg', 'Nutritious cattle feed mix', 12000, 'feed', 50, 'https://images.unsplash.com/photo-1500595046743-cd271d694d30?w=400'),
('Poultry Cage - Large', 'Durable poultry cage for 20 birds', 25000, 'equipment', 30, 'https://images.unsplash.com/photo-1548550023-2bdb3c5beed7?w=400'),
('Water Trough - 100L', 'Heavy-duty water trough', 8500, 'equipment', 45, 'https://images.unsplash.com/photo-1563291074-2bf8677ac0e5?w=400'),
('Veterinary Kit', 'Complete veterinary first aid kit', 15000, 'health', 20, 'https://images.unsplash.com/photo-1584308666744-24d5c474f2ae?w=400'),
('Goat Supplement', 'Vitamin and mineral supplement for goats', 3500, 'health', 80, 'https://images.unsplash.com/photo-1516467508483-a7212febe31a?w=400');
