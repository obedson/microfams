// Product types
export interface Product {
  id: string;
  supplier_id: string;
  name: string;
  category: string;
  description: string;
  price: number;
  unit: string;
  stock_quantity: number;
  minimum_order: number;
  location: string;
  images: string[];
  image_url: string | null;
  created_at: string;
  users?: {
    name: string;
    phone: string;
  };
}

export interface Order {
  id: string;
  product_id: string;
  buyer_id: string;
  quantity: number;
  total_price: number;
  status: 'pending' | 'confirmed' | 'shipped' | 'delivered' | 'cancelled';
  delivery_address: string;
  phone: string;
  created_at: string;
}
