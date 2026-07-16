import { Request } from 'express';

export interface User {
  id: string;
  email: string;
  name: string;
  role: 'farmer' | 'owner' | 'admin';
  phone?: string;
  created_at: string;
  updated_at: string;
}

export interface AuthenticatedRequest extends Request {
  user?: User;
}

export interface Property {
  id: string;
  organization_id: string;
  owner_id: string;
  title: string;
  description: string;
  livestock_type: 'poultry' | 'pig' | 'cattle' | 'fishery' | 'goat' | 'rabbit' | 'other';
  space_type: 'empty_land' | 'equipped_house' | 'empty_house';
  size: number;
  size_unit: 'm2' | 'units';
  city: string;
  lga: string;
  price_per_month: number;
  available_from: string;
  available_to: string;
  amenities: string[];
  images: string[];
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  message?: string;
  error?: string;
}
