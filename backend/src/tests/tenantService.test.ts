import { TenantService } from '../services/tenantService.js';
import { OrganizationMembership, TenantRepository } from '../types/tenant.js';

const membership = (organizationId: string, role: OrganizationMembership['role'] = 'member'): OrganizationMembership => ({
  id: `membership-${organizationId}`,
  userId: 'user-1',
  organizationId,
  role,
  permissions: ['farms.read'],
  organization: {
    id: organizationId,
    name: `Organization ${organizationId}`,
    slug: organizationId,
    type: 'cooperative',
    jurisdiction: 'NG',
    defaultCurrency: 'NGN',
    timezone: 'Africa/Lagos',
    status: 'active',
  },
});

const repository = (memberships: OrganizationMembership[]): TenantRepository => ({
  findActiveMembership: jest.fn(async (_userId, organizationId) => memberships.find((item) => item.organizationId === organizationId) ?? null),
  listActiveMemberships: jest.fn().mockResolvedValue(memberships),
});

describe('TenantService', () => {
  it('automatically selects the only active membership', async () => {
    const service = new TenantService(repository([membership('org-1', 'owner')]));
    await expect(service.resolve('user-1')).resolves.toMatchObject({ id: 'org-1', role: 'owner', userId: 'user-1' });
  });

  it('requires an explicit selection when a user belongs to multiple organizations', async () => {
    const service = new TenantService(repository([membership('org-1'), membership('org-2')]));
    await expect(service.resolve('user-1')).rejects.toMatchObject({
      code: 'TENANT_SELECTION_REQUIRED', status: 400,
    });
  });

  it('rejects an organization header that is not backed by active membership', async () => {
    const service = new TenantService(repository([membership('org-1')]));
    await expect(service.resolve('user-1', 'org-2')).rejects.toMatchObject({
      code: 'TENANT_ACCESS_DENIED', status: 403,
    });
  });

  it('returns verified organization details for an explicit membership', async () => {
    const service = new TenantService(repository([membership('org-2', 'finance_manager')]));
    await expect(service.resolve('user-1', 'org-2')).resolves.toMatchObject({
      id: 'org-2', jurisdiction: 'NG', defaultCurrency: 'NGN', role: 'finance_manager',
    });
  });
});
