import { organizationInvitationController } from '../controllers/organizationInvitationController.js';
import { organizationInvitationService } from '../services/organizationInvitationService.js';

jest.mock('../services/organizationInvitationService.js', () => ({
  organizationInvitationService: {
    create: jest.fn(),
    accept: jest.fn(),
    revoke: jest.fn(),
    list: jest.fn(),
  },
}));

const organizationId = '11111111-1111-4111-8111-111111111111';
const actorId = '22222222-2222-4222-8222-222222222222';
const invitationId = '33333333-3333-4333-8333-333333333333';
const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
const tenant = {
  id: organizationId,
  name: 'Growers Cooperative',
  slug: 'growers',
  type: 'cooperative',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-1',
  userId: actorId,
  role: 'owner',
  permissions: [],
};

const request = (overrides: Record<string, unknown> = {}) => ({
  user: { id: actorId },
  tenant,
  body: {},
  params: {},
  header: jest.fn((name: string) => (
    name === 'Idempotency-Key' ? 'organization-invite-request-1' : undefined
  )),
  ...overrides,
});
const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  res.set = jest.fn().mockReturnValue(res);
  return res;
};

describe('organization invitation API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('creates an email-bound invitation under verified tenant context', async () => {
    (organizationInvitationService.create as jest.Mock).mockResolvedValue({
      invitationId,
      token: 'x'.repeat(43),
      tokenAvailable: true,
    });
    const res = response();

    await organizationInvitationController.create(request({
      body: {
        email: 'invitee@example.com',
        role: 'member',
        permissions: ['groups.membership.manage'],
        expiresAt,
        organizationId: 'attacker-organization',
      },
    }) as any, res);

    expect(organizationInvitationService.create).toHaveBeenCalledWith(
      expect.objectContaining({
        organizationId,
        actorId,
        email: 'invitee@example.com',
        role: 'member',
        idempotencyKey: 'organization-invite-request-1',
      }),
    );
    expect(res.set).toHaveBeenCalledWith('Cache-Control', 'no-store');
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires idempotency before creating an invitation', async () => {
    const res = response();
    await organizationInvitationController.create(request({
      body: {
        email: 'invitee@example.com',
        role: 'viewer',
        expiresAt,
      },
      header: jest.fn(),
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(organizationInvitationService.create).not.toHaveBeenCalled();
  });

  it('accepts an invitation for the authenticated account without tenant context', async () => {
    (organizationInvitationService.accept as jest.Mock).mockResolvedValue({
      organizationId,
      membershipId: 'membership-2',
      accepted: true,
    });
    const res = response();

    await organizationInvitationController.accept(request({
      tenant: undefined,
      body: { token: 'x'.repeat(43), actorId: 'attacker' },
    }) as any, res);

    expect(organizationInvitationService.accept).toHaveBeenCalledWith(
      actorId,
      'x'.repeat(43),
    );
  });

  it('lists invitations only for the verified tenant', async () => {
    (organizationInvitationService.list as jest.Mock).mockResolvedValue([]);
    const res = response();

    await organizationInvitationController.list(request() as any, res);

    expect(organizationInvitationService.list).toHaveBeenCalledWith(organizationId);
  });

  it('revokes only within the verified tenant', async () => {
    (organizationInvitationService.revoke as jest.Mock).mockResolvedValue({ invitationId });
    const res = response();

    await organizationInvitationController.revoke(request({
      params: { invitationId },
    }) as any, res);

    expect(organizationInvitationService.revoke).toHaveBeenCalledWith(
      organizationId,
      actorId,
      invitationId,
    );
  });
});
