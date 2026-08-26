import { supabase } from '../../utils/supabase.js';

export type Programme = { id: string; organizationId: string; name: string; description: string; status: 'draft'|'active'|'closed' };
export type Cohort = { id: string; organizationId: string; programmeId: string; name: string; startsOn: string | null; endsOn: string | null };
export type Benefit = { id: string; organizationId: string; programmeId: string; name: string; description: string };
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
  async createCohort(organizationId: string, programmeId: string, input: { name: string; startsOn?: string; endsOn?: string }): Promise<Cohort> { if (!input.name?.trim()) throw new Error('COHORT_NAME_REQUIRED'); if (input.startsOn && input.endsOn && input.endsOn < input.startsOn) throw new Error('COHORT_DATE_RANGE_INVALID'); const { data, error } = await supabase.from('institutional_programme_cohorts').insert({ organization_id: organizationId, programme_id: programmeId, name: input.name.trim(), starts_on: input.startsOn ?? null, ends_on: input.endsOn ?? null }).select('*').single(); if (error) throw error; return this.mapCohort(data); }
  async createBenefit(organizationId: string, programmeId: string, input: { name: string; description?: string }): Promise<Benefit> { if (!input.name?.trim()) throw new Error('BENEFIT_NAME_REQUIRED'); const { data, error } = await supabase.from('institutional_programme_benefits').insert({ organization_id: organizationId, programme_id: programmeId, name: input.name.trim(), description: input.description?.trim() ?? '' }).select('*').single(); if (error) throw error; return this.mapBenefit(data); }
  private mapCohort(row: any): Cohort { return { id: row.id, organizationId: row.organization_id, programmeId: row.programme_id, name: row.name, startsOn: row.starts_on, endsOn: row.ends_on }; }
  private mapBenefit(row: any): Benefit { return { id: row.id, organizationId: row.organization_id, programmeId: row.programme_id, name: row.name, description: row.description }; }
  private map(row: any): Programme { return { id: row.id, organizationId: row.organization_id, name: row.name, description: row.description, status: row.status }; }
}
export const programmeService = new ProgrammeService();
