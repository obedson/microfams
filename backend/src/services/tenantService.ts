import { OrganizationMembership, TenantContext, TenantRepository } from '../types/tenant.js';

export class TenantResolutionError extends Error {
  constructor(
    public readonly code: 'TENANT_MEMBERSHIP_REQUIRED' | 'TENANT_ACCESS_DENIED' | 'TENANT_SELECTION_REQUIRED',
    public readonly status: 400 | 403,
    message: string,
  ) {
    super(message);
  }
}

export class TenantService {
  constructor(private readonly repository: TenantRepository) {}

  async resolve(userId: string, requestedOrganizationId?: string): Promise<TenantContext> {
    let membership: OrganizationMembership | null;

    if (requestedOrganizationId) {
      membership = await this.repository.findActiveMembership(userId, requestedOrganizationId);
      if (!membership) {
        throw new TenantResolutionError('TENANT_ACCESS_DENIED', 403, 'You do not have active access to that organization.');
      }
    } else {
      const memberships = await this.repository.listActiveMemberships(userId);
      if (memberships.length === 0) {
        throw new TenantResolutionError('TENANT_MEMBERSHIP_REQUIRED', 403, 'An active organization membership is required.');
      }
      if (memberships.length > 1) {
        throw new TenantResolutionError('TENANT_SELECTION_REQUIRED', 400, 'Select an organization for this request.');
      }
      membership = memberships[0];
    }

    return {
      ...membership.organization,
      membershipId: membership.id,
      userId: membership.userId,
      role: membership.role,
      permissions: membership.permissions,
    };
  }
}
