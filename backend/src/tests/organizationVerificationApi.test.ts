import { jest } from '@jest/globals';
import { organizationController } from '../controllers/organizationController.js';
import { organizationVerificationService } from '../domains/organizations/organizationVerificationService.js';

jest.mock('../domains/organizations/organizationVerificationService.js', () => ({
  organizationVerificationService: {
    start: jest.fn(),
    getCurrent: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const tenant = {
  id: 'tenant-1',
  name: 'Ada Farms',
  slug: 'ada-farms',
  type: 'farm_business',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-1',
  userId: 'user-1',
  role: 'owner',
  permissions: [],
};

describe('organization verification API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('requires explicit authority attestation', async () => {
    const res = response();
    await organizationController.submitVerification({
      body: { registrationType: 'cac_rc', registrationNumber: 'RC/1234567' },
      user: { id: 'user-1' },
      tenant,
      headers: {},
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it('submits provider evidence in the authenticated tenant', async () => {
    (organizationVerificationService.start as jest.Mock).mockResolvedValue({
      id: 'request-1',
      state: 'verified',
      maskedRegistration: 'RC/****4567',
    } as never);
    const res = response();

    await organizationController.submitVerification({
      body: {
        registrationType: 'cac_rc',
        registrationNumber: 'rc/1234567',
        authorityAttested: true,
      },
      user: { id: 'user-1' },
      tenant,
      headers: { 'idempotency-key': 'organization-command-1' },
    } as any, res);

    expect(organizationVerificationService.start).toHaveBeenCalledWith(expect.objectContaining({
      organizationId: 'tenant-1',
      userId: 'user-1',
      organizationName: 'Ada Farms',
      organizationType: 'farm_business',
      jurisdiction: 'NG',
      registrationType: 'cac_rc',
      registrationNumber: 'RC/1234567',
      idempotencyKey: 'organization-command-1',
    }));
    expect(res.status).toHaveBeenCalledWith(202);
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0])).not.toContain('RC/1234567');
  });

  it('uses an opaque idempotency key when the client omits one', async () => {
    (organizationVerificationService.start as jest.Mock).mockResolvedValue({
      id: 'request-1',
      state: 'verified',
    } as never);
    const res = response();

    await organizationController.submitVerification({
      body: {
        registrationType: 'cac_rc',
        registrationNumber: 'RC/1234567',
        authorityAttested: true,
      },
      user: { id: 'user-1' },
      tenant,
      headers: {},
    } as any, res);

    const command = (organizationVerificationService.start as jest.Mock).mock.calls[0][0] as any;
    expect(command.idempotencyKey).toMatch(/^organization-verification-[0-9a-f-]{36}$/);
    expect(command.idempotencyKey).not.toContain('1234567');
  });

  it('reads existing status without requiring a new provider operation', async () => {
    (organizationVerificationService.getCurrent as jest.Mock).mockResolvedValue({
      id: 'request-1',
      state: 'verified',
      maskedRegistration: 'RC/****4567',
    } as never);
    const res = response();

    await organizationController.getVerification({
      user: { id: 'user-1' },
      tenant,
      headers: {},
    } as any, res);

    expect(organizationVerificationService.getCurrent).toHaveBeenCalledWith('tenant-1', 'user-1');
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
  });
});
