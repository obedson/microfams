import { organizationMembershipController } from '../controllers/organizationMembershipController.js';
import { organizationMembershipService } from '../services/organizationMembershipService.js';

jest.mock('../services/organizationMembershipService.js', () => ({
  organizationMembershipService: {
    list: jest.fn(),
    updateAccess: jest.fn(),
  },
}));

const organizationId = '11111111-1111-4111-8111-111111111111';
const actorId = '22222222-2222-4222-8222-222222222222';
const membershipId = '33333333-3333-4333-8333-333333333333';
const tenant = {
  id: organizationId,
  name: 'Growers Cooperative',
  slug: 'growers',
  type: 'cooperative',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-owner',
  userId: actorId,
  role: 'owner',
  permissions: [],
};

const request = (overrides: Record<string, unknown> = {}) => ({
  user: { id: actorId },
  tenant,
  body: {},
  params: {},
  ...overrides,
});
const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  res.set = jest.fn().mockReturnValue(res);
  return res;
};

describe('organization membership access API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('lists memberships only for the verified tenant', async () => {
    (organizationMembershipService.list as jest.Mock).mockResolvedValue([]);
    const res = response();

    await organizationMembershipController.list(request() as any, res);

    expect(organizationMembershipService.list).toHaveBeenCalledWith(organizationId);
    expect(res.json).toHaveBeenCalledWith({ success: true, data: [] });
  });

  it('updates a non-owner role and permissions under verified tenant context', async () => {
    (organizationMembershipService.updateAccess as jest.Mock).mockResolvedValue({
      id: membershipId,
      role: 'finance_manager',
      permissions: ['financial.*'],
    });
    const res = response();

    await organizationMembershipController.updateAccess(request({
      params: { membershipId },
      body: {
        organizationId: 'attacker-organization',
        role: 'finance_manager',
        permissions: ['financial.*', 'groups.read'],
      },
    }) as any, res);

    expect(organizationMembershipService.updateAccess).toHaveBeenCalledWith({
      organizationId,
      actorId,
      membershipId,
      role: 'finance_manager',
      permissions: ['financial.*', 'groups.read'],
    });
    expect(res.set).toHaveBeenCalledWith('Cache-Control', 'no-store');
  });

  it('rejects owner assignment before persistence', async () => {
    const res = response();

    await organizationMembershipController.updateAccess(request({
      params: { membershipId },
      body: { role: 'owner', permissions: [] },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(organizationMembershipService.updateAccess).not.toHaveBeenCalled();
  });

  it('maps ownership workflow denial to forbidden', async () => {
    (organizationMembershipService.updateAccess as jest.Mock).mockRejectedValue(
      new Error('ORGANIZATION_OWNERSHIP_WORKFLOW_REQUIRED'),
    );
    const res = response();

    await organizationMembershipController.updateAccess(request({
      params: { membershipId },
      body: { role: 'admin', permissions: [] },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'ORGANIZATION_OWNERSHIP_WORKFLOW_REQUIRED',
    });
  });
});
