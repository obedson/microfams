import supabase from '../utils/supabase.js';
import { Property } from '../types/index.js';

export class PropertyModel {
  static async create(propertyData: Omit<Property, 'id' | 'created_at' | 'updated_at'>): Promise<Property> {
    const { data, error } = await supabase
      .from('properties')
      .insert(propertyData)
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  static async findAll(filters?: {
    livestock_type?: string;
    city?: string;
    min_price?: number;
    max_price?: number;
  }): Promise<Property[]> {
    let query = supabase.from('properties').select('*').eq('is_active', true);

    if (filters?.livestock_type) {
      query = query.eq('livestock_type', filters.livestock_type);
    }
    if (filters?.city) {
      query = query.ilike('city', `%${filters.city}%`);
    }
    if (filters?.min_price) {
      query = query.gte('price_per_month', filters.min_price);
    }
    if (filters?.max_price) {
      query = query.lte('price_per_month', filters.max_price);
    }

    const { data, error } = await query;
    if (error) throw error;
    return data || [];
  }

  static async findById(id: string, organizationId?: string): Promise<any | null> {
    let query = supabase
      .from('properties')
      .select(`
        *,
        users!properties_owner_id_fkey (
          id,
          name,
          email
        )
      `)
      .eq('id', id);

    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data, error } = await query.single();

    if (error) return null;
    return {
      ...data,
      owner_name: data.users?.name,
      owner_email: data.users?.email,
    };
  }

  static async update(id: string, organizationId: string, updates: Partial<Property>): Promise<Property | null> {
    const { data, error } = await supabase
      .from('properties')
      .update(updates)
      .eq('id', id)
      .eq('organization_id', organizationId)
      .select()
      .single();

    if (error) return null;
    return data;
  }

  static async delete(id: string, organizationId: string): Promise<boolean> {
    const { error } = await supabase
      .from('properties')
      .delete()
      .eq('id', id)
      .eq('organization_id', organizationId);

    return !error;
  }
}
