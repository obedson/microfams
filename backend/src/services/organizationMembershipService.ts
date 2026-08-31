import { supabase } from '../utils/supabase.js';
import { OrganizationRole } from '../types/tenant.js';

export interface OrganizationMembershipAccess {
  id: string;
  userId: string;
  role: OrganizationRole;
  permissions: string[];
  status: string;
  joinedAt: string | null;
  updatedAt?: string;
  user?: {
    email: string;
    name: string | null;
  };
}

interface MembershipAccessRow {
  id: string;
  user_id: string;
  role: OrganizationRole;
  permissions: string[];
  status: string;
  joined_at: string | null;
  updated_at?: string;
  users?: {
    email: string;
    name: string | null;
  } | Array<{
    email: string;
    name: string | null;
  }> | null;
}

const mapMembership = (row: MembershipAccessRow): OrganizationMembershipAccess => {
  const user = Array.isArray(row.users) ? row.users[0] : row.users;
  return {
    id: row.id,
    userId: row.user_id,
    role: row.role,
    permissions: row.permissions ?? [],
    status: row.status,
    joinedAt: row.joined_at,
    ...(row.updated_at ? { updatedAt: row.updated_at } : {}),
    ...(user ? { user } : {}),
  };
};

export class OrganizationMembershipService {
  async list(organizationId: string) {
    const { data, error } = await supabase
      .from('organization_memberships')
      .select('id, user_id, role, permissions, status, joined_at, users!organization_memberships_user_id_fkey(email, name)')
      .eq('organization_id', organizationId)
      .neq('status', 'removed')
      .order('created_at', { ascending: true });
    if (error) throw error;
    return (data as MembershipAccessRow[] | null ?? []).map(mapMembership);
  }

  async updateAccess(input: {
    organizationId: string;
    actorId: string;
    membershipId: string;
    role: Exclude<OrganizationRole, 'owner'>;
    permissions: string[];
  }) {
    const { data, error } = await supabase.rpc(
      'update_organization_membership_access',
      {
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_membership_id: input.membershipId,
        p_role: input.role,
        p_permissions: input.permissions,
      },
    );
    if (error) throw error;
    return mapMembership(data as MembershipAccessRow);
  }
}

export const organizationMembershipService = new OrganizationMembershipService();
