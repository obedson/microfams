import express from 'express';
import request from 'supertest';
import profileRoutes from '../routes/profile.js';
import { identityVerificationService } from '../domains/identity/identityVerificationService.js';
import { supabase } from '../utils/supabase.js';

const ORGANIZATION_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_ORGANIZATION_ID = '22222222-2222-4222-8222-222222222222';
const BVN = '12345678901';
const mockEnabledFlags = new Set<string>();
const mockFeatureChecks = jest.fn();

jest.mock('../middleware/auth.js', () => ({
  authenticateToken: (req: any, res: any, next: any) => {
    if (req.headers.authorization !== 'Bearer valid-token') {
      return res.status(401).json({ success: false, error: 'Access token required' });
    }
    req.user = { id: 'user-1', role: 'farmer' };
    return next();
  },
}));

jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, res: any, next: any) => {
    if (req.headers['x-organization-id'] !== ORGANIZATION_ID) {
      return res.status(403).json({
        success: false,
        error: 'TENANT_ACCESS_DENIED',
        message: 'You do not have active access to that organization.',
      });
    }
    req.tenant = { id: ORGANIZATION_ID, jurisdiction: 'NG', role: 'member', permissions: [] };
    return next();
  },
}));

jest.mock('../middleware/requireFeature.js', () => ({
  requireFeature: (key: string) => (req: any, res: any, next: any) => {
    mockFeatureChecks(key, req.tenant?.id);
    if (!mockEnabledFlags.has(key)) {
      return res.status(503).json({
        success: false,
        error: 'FEATURE_DISABLED',
        feature: key,
        message: 'This capability is not currently enabled for your organization.',
      });
    }
    return next();
  },
}));

jest.mock('../domains/identity/identityVerificationService.js', () => ({
  identityVerificationService: {
    start: jest.fn(),
    confirm: jest.fn(),
  },
}));

jest.mock('../utils/supabase.js', () => ({
  supabase: { from: jest.fn() },
}));

const app = express();
app.use(express.json());
app.use('/api/auth/profile', profileRoutes);

const mockUserLookup = (data: unknown = { name: 'Ada Farmer', phone: '08031234123' }, error: unknown = null) => {
  const single = jest.fn().mockResolvedValue({ data, error } as never);
  const eq = jest.fn().mockReturnValue({ single });
  const select = jest.fn().mockReturnValue({ eq });
  (supabase.from as jest.Mock).mockReturnValue({ select });
};

const enabledRequest = () => request(app)
  .post('/api/auth/profile/verify-bvn')
  .set('Authorization', 'Bearer valid-token')
  .set('X-Organization-Id', ORGANIZATION_ID)
  .set('Idempotency-Key', 'bvn-request-001');

describe('progressive BVN route API contract', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockEnabledFlags.clear();
    mockEnabledFlags.add('integration.identity_verification');
    mockEnabledFlags.add('integration.identity_bvn_verification');
    mockUserLookup();
    (identityVerificationService.start as jest.Mock).mockResolvedValue({
      id: 'request-bvn',
      evidenceType: 'bvn',
      state: 'awaiting_otp',
      maskedDestination: '0803****123',
    } as never);
  });

  it('requires authentication before tenant or feature evaluation', async () => {
    await request(app)
      .post('/api/auth/profile/verify-bvn')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .set('Idempotency-Key', 'bvn-request-001')
      .send({ bvn: BVN, consent: true })
      .expect(401, { success: false, error: 'Access token required' });

    expect(mockFeatureChecks).not.toHaveBeenCalled();
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it('rejects an organization outside the authenticated membership boundary', async () => {
    const response = await request(app)
      .post('/api/auth/profile/verify-bvn')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', OTHER_ORGANIZATION_ID)
      .set('Idempotency-Key', 'bvn-request-001')
      .send({ bvn: BVN, consent: true })
      .expect(403);

    expect(response.body).toEqual({
      success: false,
      error: 'TENANT_ACCESS_DENIED',
      message: 'You do not have active access to that organization.',
    });
    expect(JSON.stringify(response.body)).not.toContain(ORGANIZATION_ID);
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it.each([
    'integration.identity_verification',
    'integration.identity_bvn_verification',
  ])('fails closed when %s is disabled', async (disabledFlag) => {
    mockEnabledFlags.delete(disabledFlag);

    const response = await enabledRequest()
      .send({ bvn: BVN, consent: true })
      .expect(503);

    expect(response.body).toEqual(expect.objectContaining({
      success: false,
      error: 'FEATURE_DISABLED',
      feature: disabledFlag,
    }));
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it.each([
    {},
    { bvn: BVN, consent: false },
  ])('requires explicit true consent before storage or provider access', async (body) => {
    await enabledRequest().send(body).expect(400);

    expect(supabase.from).not.toHaveBeenCalled();
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it.each(['123', '1234567890A', '123456789012'])('rejects malformed BVN input before storage: %s', async (bvn) => {
    await enabledRequest().send({ bvn, consent: true }).expect(400);

    expect(supabase.from).not.toHaveBeenCalled();
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it.each([undefined, 'short'])('requires a bounded client idempotency key: %s', async (idempotencyKey) => {
    let command = request(app)
      .post('/api/auth/profile/verify-bvn')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', ORGANIZATION_ID);
    if (idempotencyKey) command = command.set('Idempotency-Key', idempotencyKey);

    const response = await command.send({ bvn: BVN, consent: true }).expect(400);

    expect(response.body.error).toBe('Idempotency-Key header must contain between 8 and 128 characters');
    expect(supabase.from).not.toHaveBeenCalled();
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });

  it('binds the command to the authenticated user, selected tenant, consent, and idempotency key', async () => {
    const response = await enabledRequest().send({ bvn: BVN, consent: true }).expect(200);

    expect(identityVerificationService.start).toHaveBeenCalledWith(expect.objectContaining({
      organizationId: ORGANIZATION_ID,
      userId: 'user-1',
      evidenceType: 'bvn',
      identifier: BVN,
      registeredPhone: '08031234123',
      consentVersion: 'identity-verification-v2',
      consentTextHash: expect.stringMatching(/^[a-f0-9]{64}$/),
      idempotencyKey: 'bvn-request-001',
    }));
    expect(response.body).toEqual(expect.objectContaining({
      id: 'request-bvn',
      maskedDestination: '0803****123',
    }));
    expect(JSON.stringify(response.body)).not.toContain(BVN);
  });

  it('forwards the same idempotency facts on an exact client replay', async () => {
    await enabledRequest().send({ bvn: BVN, consent: true }).expect(200);
    await enabledRequest().send({ bvn: BVN, consent: true }).expect(200);

    expect(identityVerificationService.start).toHaveBeenCalledTimes(2);
    expect((identityVerificationService.start as jest.Mock).mock.calls.map(([command]: any[]) => ({
      organizationId: command.organizationId,
      userId: command.userId,
      identifier: command.identifier,
      idempotencyKey: command.idempotencyKey,
    }))).toEqual([
      { organizationId: ORGANIZATION_ID, userId: 'user-1', identifier: BVN, idempotencyKey: 'bvn-request-001' },
      { organizationId: ORGANIZATION_ID, userId: 'user-1', identifier: BVN, idempotencyKey: 'bvn-request-001' },
    ]);
  });

  it('returns the stable provider-unavailable contract without provider details', async () => {
    (identityVerificationService.start as jest.Mock).mockRejectedValue(
      new Error('Identity provider is temporarily unavailable; start a new verification request') as never,
    );

    const response = await enabledRequest().send({ bvn: BVN, consent: true }).expect(422);

    expect(response.body).toEqual({
      error: 'Identity provider is temporarily unavailable; start a new verification request',
    });
    expect(JSON.stringify(response.body)).not.toContain(BVN);
  });

  it('redacts unexpected provider and persistence error details', async () => {
    (identityVerificationService.start as jest.Mock).mockRejectedValue(
      new Error('axios host=provider.internal bearer=secret-token raw-bvn=' + BVN) as never,
    );

    const response = await enabledRequest().send({ bvn: BVN, consent: true }).expect(422);

    expect(response.body).toEqual({ error: 'BVN verification could not be started' });
    expect(JSON.stringify(response.body)).not.toContain('provider.internal');
    expect(JSON.stringify(response.body)).not.toContain('secret-token');
    expect(JSON.stringify(response.body)).not.toContain(BVN);
  });

  it('does not contact the provider when the registered account phone is invalid', async () => {
    mockUserLookup({ name: 'Ada Farmer', phone: '' });

    const response = await enabledRequest().send({ bvn: BVN, consent: true }).expect(422);

    expect(response.body).toEqual({ error: 'A valid registered phone is required for identity verification' });
    expect(identityVerificationService.start).not.toHaveBeenCalled();
  });
});
