import { supabase } from '../utils/supabase.js';
import { OrganizationMembership, OrganizationRole, OrganizationType, TenantRepository } from '../types/tenant.js';

interface MembershipRow {
  id: string;
  user_id: string;
  organization_id: string;
  role: OrganizationRole;
  permissions: string[] | null;
  organization: {
    id: string;
    name: string;
    slug: string;
    type: OrganizationType;
    jurisdiction: string;
    default_currency: string;
    timezone: string;
    status: 'active' | 'suspended' | 'closed';
  };
}

const MEMBERSHIP_SELECT = `
  id,
  user_id,
  organization_id,
  role,
  permissions,
  organization:organizations!inner(
    id, name, slug, type, jurisdiction, default_currency, timezone, status
  )
`;

const mapMembership = (row: MembershipRow): OrganizationMembership => ({
  id: row.id,
  userId: row.user_id,
  organizationId: row.organization_id,
  role: row.role,
  permissions: row.permissions ?? [],
  organization: {
    id: row.organization.id,
    name: row.organization.name,
    slug: row.organization.slug,
    type: row.organization.type,
    jurisdiction: row.organization.jurisdiction,
    defaultCurrency: row.organization.default_currency,
    timezone: row.organization.timezone,
    status: row.organization.status,
  },
});

export class SupabaseTenantRepository implements TenantRepository {
  async findActiveMembership(userId: string, organizationId: string): Promise<OrganizationMembership | null> {
    const { data, error } = await supabase
      .from('organization_memberships')
      .select(MEMBERSHIP_SELECT)
      .eq('user_id', userId)
      .eq('organization_id', organizationId)
      .eq('status', 'active')
      .eq('organizations.status', 'active')
      .maybeSingle();

    if (error) throw error;
    return data ? mapMembership(data as unknown as MembershipRow) : null;
  }

  async listActiveMemberships(userId: string): Promise<OrganizationMembership[]> {
    const { data, error } = await supabase
      .from('organization_memberships')
      .select(MEMBERSHIP_SELECT)
      .eq('user_id', userId)
      .eq('status', 'active')
      .eq('organizations.status', 'active');

    if (error) throw error;
    return ((data ?? []) as unknown as MembershipRow[]).map(mapMembership);
  }
}
