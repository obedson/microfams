import supabase from '../utils/supabase.js';

export class LocationModel {
  static async getAllStates() {
    const { data, error } = await supabase
      .from('states')
      .select('*')
      .order('name');
    if (error) throw error;
    return data;
  }

  static async getLGAsByState(stateId: number) {
    const { data, error } = await supabase
      .from('lgas')
      .select('*')
      .eq('state_id', stateId)
      .order('name');
    if (error) throw error;
    return data;
  }
}
