import supabase from '../utils/supabase.js';

export interface FarmRecord {
  id: string;
  organization_id: string;
  farmer_id: string;
  property_id: string;
  livestock_type: string;
  livestock_count: number;
  feed_consumption: number;
  mortality_count: number;
  expenses: number;
  expense_category: string;
  notes?: string;
  record_date: string;
  created_at: string;
}

export class FarmRecordModel {
  static async create(recordData: Omit<FarmRecord, 'id' | 'created_at'>) {
    const { data, error } = await supabase
      .from('farm_records')
      .insert([recordData])
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  static async findByFarmer(farmerId: string, organizationId: string) {
    const { data, error } = await supabase
      .from('farm_records')
      .select('*')
      .eq('farmer_id', farmerId)
      .eq('organization_id', organizationId)
      .order('record_date', { ascending: false });

    if (error) throw error;
    return data;
  }

  static async findByProperty(propertyId: string, organizationId: string) {
    const { data, error } = await supabase
      .from('farm_records')
      .select('*')
      .eq('property_id', propertyId)
      .eq('organization_id', organizationId)
      .order('record_date', { ascending: false });

    if (error) throw error;
    return data;
  }

  static async getAnalytics(farmerId: string, organizationId: string, startDate: string, endDate: string) {
    const { data, error } = await supabase
      .from('farm_records')
      .select('*')
      .eq('farmer_id', farmerId)
      .eq('organization_id', organizationId)
      .gte('record_date', startDate)
      .lte('record_date', endDate);

    if (error) throw error;
    return data;
  }

  static async update(id: string, organizationId: string, updates: Partial<FarmRecord>) {
    const { data, error } = await supabase
      .from('farm_records')
      .update(updates)
      .eq('id', id)
      .eq('organization_id', organizationId)
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  static async delete(id: string, organizationId: string) {
    const { error } = await supabase
      .from('farm_records')
      .delete()
      .eq('id', id)
      .eq('organization_id', organizationId);

    if (error) throw error;
  }
}
