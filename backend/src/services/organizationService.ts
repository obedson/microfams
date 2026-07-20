import { OrganizationMembership, OrganizationType, TenantRepository } from '../types/tenant.js';

export interface CreateOrganizationInput {
  name: string;
  legalName?: string;
  slug: string;
  type: OrganizationType;
  jurisdiction: string;
  defaultCurrency: string;
  timezone: string;
}

export interface OrganizationBranding {
  displayName: string | null;
  logoUrl: string | null;
  primaryColor: string | null;
  secondaryColor: string | null;
  supportEmail: string | null;
  supportPhone: string | null;
  customDomain: string | null;
}

export interface OrganizationRepository extends TenantRepository {
  create(userId: string, input: CreateOrganizationInput): Promise<OrganizationMembership>;
  getBranding(organizationId: string): Promise<OrganizationBranding | null>;
  updateBranding(organizationId: string, userId: string, branding: Partial<OrganizationBranding>): Promise<OrganizationBranding>;
}

export class OrganizationService {
  constructor(private readonly repository: OrganizationRepository) {}

  listForUser(userId: string) {
    return this.repository.listActiveMemberships(userId);
  }

  create(userId: string, input: CreateOrganizationInput) {
    return this.repository.create(userId, input);
  }

  getBranding(organizationId: string) {
    return this.repository.getBranding(organizationId);
  }

  updateBranding(organizationId: string, userId: string, branding: Partial<OrganizationBranding>) {
    return this.repository.updateBranding(organizationId, userId, branding);
  }
}
