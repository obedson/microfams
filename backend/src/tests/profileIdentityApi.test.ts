import { jest } from '@jest/globals';
import { profileController } from '../controllers/profileController.js';
import { identityVerificationService } from '../domains/identity/identityVerificationService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../domains/identity/identityVerificationService.js', () => ({
  identityVerificationService: {
    start: jest.fn(),
    confirm: jest.fn(),
  },
}));

jest.mock('../utils/supabase.js', () => ({
  supabase: { from: jest.fn() },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const mockUserLookup = (name = 'Ada Farmer') => {
  const single = jest.fn().mockResolvedValue({ data: { name }, error: null } as never);
  const eq = jest.fn().mockReturnValue({ single });
  const select = jest.fn().mockReturnValue({ eq });
  (supabase.from as jest.Mock).mockReturnValue({ select });
};

describe('identity verification API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects malformed NIN values before accessing storage or providers', async () => {
    const res = response();

    await profileController.verifyNIN({
      body: { nin: '123', consent: true },
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1' },
      headers: {},
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(supabase.from).not.toHaveBeenCalled();
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it('starts verification in the authenticated tenant with explicit consent', async () => {
    mockUserLookup();
    (identityVerificationService.start as jest.Mock).mockResolvedValue({
      requestId: 'request-1',
      state: 'awaiting_otp',
      maskedDestination: '0803****123',
    } as never);
    const res = response();

    await profileController.verifyNIN({
      body: { nin: '12345678901', consent: true },
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1' },
      headers: { 'idempotency-key': 'identity-request-001' },
    } as any, res);

    expect(identityVerificationService.start).toHaveBeenCalledWith(expect.objectContaining({
      organizationId: 'tenant-1',
      userId: 'user-1',
      evidenceType: 'nin',
      identifier: '12345678901',
      firstName: 'Ada',
      lastName: 'Farmer',
      idempotencyKey: 'identity-request-001',
    }));
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      requestId: 'request-1',
      maskedDestination: '0803****123',
    }));
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0])).not.toContain('12345678901');
  });

  it('uses an opaque random idempotency key when the client omits one', async () => {
    mockUserLookup();
    (identityVerificationService.start as jest.Mock).mockResolvedValue({
      requestId: 'request-2',
      state: 'awaiting_otp',
    } as never);
    const res = response();

    await profileController.verifyNIN({
      body: { nin: '12345678901', consent: true },
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1' },
      headers: {},
    } as any, res);

    const command = (identityVerificationService.start as jest.Mock).mock.calls[0][0] as any;
    expect(command.idempotencyKey).toMatch(/^identity-[0-9a-f-]{36}$/);
    expect(command.idempotencyKey).not.toContain('12345678901');
  });

  it('confirms an OTP only inside the authenticated tenant', async () => {
    (identityVerificationService.confirm as jest.Mock).mockResolvedValue({
      requestId: 'request-1',
      state: 'verified',
    } as never);
    const res = response();

    await profileController.confirmOTP({
      body: { requestRef: 'request-1', otp: '123456' },
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1' },
      headers: {},
    } as any, res);

    expect(identityVerificationService.confirm).toHaveBeenCalledWith({
      organizationId: 'tenant-1',
      userId: 'user-1',
      requestId: 'request-1',
      otp: '123456',
    });
    expect(res.json).toHaveBeenCalledWith({ requestId: 'request-1', state: 'verified' });
  });

  it('keeps the legacy send-otp step generic and never accepts a replacement destination', async () => {
    const res = response();

    await profileController.sendOTP({
      body: { requestRef: 'request-1', fullPhone: '08039999123' },
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1' },
      headers: {},
    } as any, res);

    expect(res.json).toHaveBeenCalledWith({
      success: true,
      message: 'OTP was sent to the verified identity destination',
    });
    expect(identityVerificationService.start).not.toHaveBeenCalled();
    expect(identityVerificationService.confirm).not.toHaveBeenCalled();
  });
});
