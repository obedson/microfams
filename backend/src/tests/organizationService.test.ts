import { OrganizationRepository, OrganizationService } from '../services/organizationService.js';
import { OrganizationMembership } from '../types/tenant.js';

const ownerMembership: OrganizationMembership = {
  id: 'membership-1', userId: 'user-1', organizationId: 'org-1', role: 'owner', permissions: [],
  organization: {
    id: 'org-1', name: 'Growers Cooperative', slug: 'growers', type: 'cooperative', jurisdiction: 'NG',
    defaultCurrency: 'NGN', timezone: 'Africa/Lagos', status: 'active',
  },
};

const repository = (): jest.Mocked<OrganizationRepository> => ({
  findActiveMembership: jest.fn(),
  listActiveMemberships: jest.fn().mockResolvedValue([ownerMembership]),
  create: jest.fn().mockResolvedValue(ownerMembership),
  getBranding: jest.fn().mockResolvedValue(null),
  updateBranding: jest.fn().mockResolvedValue({
    displayName: 'Growers', logoUrl: null, primaryColor: '#008000', secondaryColor: null,
    supportEmail: null, supportPhone: null, customDomain: null,
  }),
});

describe('OrganizationService', () => {
  it('returns only memberships supplied for the authenticated user', async () => {
    const store = repository();
    const service = new OrganizationService(store);
    await expect(service.listForUser('user-1')).resolves.toEqual([ownerMembership]);
    expect(store.listActiveMemberships).toHaveBeenCalledWith('user-1');
  });

  it('creates an organization through the atomic repository operation', async () => {
    const store = repository();
    const service = new OrganizationService(store);
    const input = {
      name: 'Growers Cooperative', slug: 'growers', type: 'cooperative' as const,
      jurisdiction: 'NG', defaultCurrency: 'NGN', timezone: 'Africa/Lagos',
    };
    await expect(service.create('user-1', input)).resolves.toEqual(ownerMembership);
    expect(store.create).toHaveBeenCalledWith('user-1', input);
  });

  it('updates branding only for the organization supplied by verified tenant context', async () => {
    const store = repository();
    const service = new OrganizationService(store);
    await service.updateBranding('org-1', 'user-1', { primaryColor: '#008000' });
    expect(store.updateBranding).toHaveBeenCalledWith('org-1', 'user-1', { primaryColor: '#008000' });
  });
});
