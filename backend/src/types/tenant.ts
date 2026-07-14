export type OrganizationType = 'farm_business' | 'cooperative' | 'ngo' | 'government_program' | 'agribusiness';
export type OrganizationRole = 'owner' | 'admin' | 'finance_manager' | 'program_manager' | 'farm_manager' | 'auditor' | 'member' | 'viewer';

export interface OrganizationSummary {
  id: string;
  name: string;
  slug: string;
  type: OrganizationType;
  jurisdiction: string;
  defaultCurrency: string;
  timezone: string;
  status: 'active' | 'suspended' | 'closed';
}

export interface OrganizationMembership {
  id: string;
  userId: string;
  organizationId: string;
  role: OrganizationRole;
  permissions: string[];
  organization: OrganizationSummary;
}

export interface TenantContext extends OrganizationSummary {
  membershipId: string;
  userId: string;
  role: OrganizationRole;
  permissions: string[];
}

export interface TenantRepository {
  findActiveMembership(userId: string, organizationId: string): Promise<OrganizationMembership | null>;
  listActiveMemberships(userId: string): Promise<OrganizationMembership[]>;
}
