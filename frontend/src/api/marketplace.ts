import { Product, Order } from '../types/marketplace';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

const getToken = () => {
  let token = localStorage.getItem('token');
  if (!token) {
    const authStorage = localStorage.getItem('auth-storage');
    if (authStorage) {
      const parsed = JSON.parse(authStorage);
      token = parsed.state?.token;
    }
  }
  return token;
};

// Normalize product data from API
const normalizeProduct = (data: any): Product => {
  let images: string[] = [];
  
  if (Array.isArray(data.images)) {
    images = data.images;
  } else if (typeof data.images === 'string') {
    try {
      images = JSON.parse(data.images);
      if (!Array.isArray(images)) images = [];
    } catch {
      images = [];
    }
  }
  
  return {
    ...data,
    images
  };
};

export const marketplaceApi = {
  // Products
  getProducts: async (filters?: { category?: string; location?: string }): Promise<Product[]> => {
    const params = new URLSearchParams();
    if (filters?.category) params.append('category', filters.category);
    if (filters?.location) params.append('location', filters.location);
    
    const response = await fetch(`${API_BASE}/products?${params}`);
    const data = await response.json();
    return Array.isArray(data) ? data.map(normalizeProduct) : [];
  },

  getProduct: async (id: string): Promise<Product> => {
    const response = await fetch(`${API_BASE}/products/${id}`);
    const data = await response.json();
    return normalizeProduct(data);
  },

  createProduct: async (productData: any) => {
    const token = getToken();
    const headers: any = {
      'Authorization': `Bearer ${token}`
    };
    
    // Don't set Content-Type for FormData, let browser set it
    if (!(productData instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
      productData = JSON.stringify(productData);
    }
    
    const response = await fetch(`${API_BASE}/products`, {
      method: 'POST',
      headers,
      body: productData
    });
    
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to create product');
    }
    
    return response.json();
  },

  updateProduct: async (id: string, productData: any) => {
    const token = getToken();
    
    // Always send as FormData for consistency
    let formData: FormData;
    if (productData instanceof FormData) {
      formData = productData;
    } else {
      formData = new FormData();
      Object.entries(productData).forEach(([key, value]) => {
        formData.append(key, value as string);
      });
    }
    
    const response = await fetch(`${API_BASE}/products/${id}`, {
      method: 'PATCH',
      headers: {
        'Authorization': `Bearer ${token}`
      },
      body: formData
    });
    
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to update product');
    }
    
    return response.json();
  },

  deleteProduct: async (id: string) => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/products/${id}`, {
      method: 'DELETE',
      headers: {
        'Authorization': `Bearer ${token}`
      }
    });
    
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to delete product');
    }
  },

  // Orders
  createOrder: async (orderData: any) => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/orders`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`
      },
      body: JSON.stringify(orderData)
    });
    
    const data = await response.json();
    
    if (!response.ok) {
      // Only log in development
      if (process.env.NODE_ENV === 'development') {
        console.error('Order creation failed:', data);
      }
      throw new Error(data.error || 'Failed to create order');
    }
    
    return data;
  },

  getMyOrders: async () => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/orders/my-orders`, {
      headers: {
        'Authorization': `Bearer ${token}`
      }
    });
    return response.json();
  },

  getMyProducts: async () => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/products/my-products`, {
      headers: {
        'Authorization': `Bearer ${token}`
      }
    });
    return response.json();
  },

  getMySales: async () => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/orders/my-sales`, {
      headers: {
        'Authorization': `Bearer ${token}`
      }
    });
    return response.json();
  },

  updateOrderStatus: async (id: string, status: string) => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/orders/${id}/status`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`
      },
      body: JSON.stringify({ status })
    });
    
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to update order status');
    }
    
    return response.json();
  }
};
