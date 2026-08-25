import { supabase } from '../../utils/supabase.js';

export type Programme = { id: string; organizationId: string; name: string; description: string; status: 'draft'|'active'|'closed' };
export class ProgrammeService {
  async list(organizationId: string): Promise<Programme[]> {
    const { data, error } = await supabase.from('institutional_programmes').select('*').eq('organization_id', organizationId).order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(this.map);
  }
  async create(organizationId: string, input: { name: string; description?: string }): Promise<Programme> {
    if (!input.name?.trim()) throw new Error('PROGRAMME_NAME_REQUIRED');
    const { data, error } = await supabase.from('institutional_programmes').insert({ organization_id: organizationId, name: input.name.trim(), description: input.description?.trim() ?? '' }).select('*').single();
    if (error) throw error;
    return this.map(data);
  }
  private map(row: any): Programme { return { id: row.id, organizationId: row.organization_id, name: row.name, description: row.description, status: row.status }; }
}
export const programmeService = new ProgrammeService();
