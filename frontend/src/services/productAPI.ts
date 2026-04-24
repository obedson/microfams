const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface Product {
  id: string;
  name: string;
  description: string;
  price: number;
  category: string;
  location: string;
  image_url?: string;
  stock_quantity: number;
  unit: string;
  minimum_order: number;
  bulk_discount_rate?: number;
  minimum_bulk_quantity?: number;
}

interface BulkDiscountResult {
  original_price: number;
  discounted_price: number;
  total_saving: number;
  applied_discount: number;
}

class ProductAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };
  }

  async getProducts(params?: { category?: string; location?: string }): Promise<Product[]> {
    const query = new URLSearchParams(params as any).toString();
    const response = await fetch(`${API_BASE}/products?${query}`);
    if (!response.ok) throw new Error('Failed to fetch products');
    return response.json();
  }

  async getRecommendations(): Promise<Product[]> {
    const response = await fetch(`${API_BASE}/products/recommendations`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch recommendations');
    return response.json();
  }

  async getBulkDiscount(productId: string, quantity: number): Promise<BulkDiscountResult> {
    const response = await fetch(`${API_BASE}/products/${productId}/bulk-discount?quantity=${quantity}`);
    if (!response.ok) throw new Error('Failed to calculate discount');
    return response.json();
  }
}

export const productAPI = new ProductAPI();
export type { Product, BulkDiscountResult };
