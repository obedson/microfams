import express from 'express';
import request from 'supertest';
import organizationRoutes from '../routes/organizations.js';
import { organizationVerificationService } from '../domains/organizations/organizationVerificationService.js';

const ORGANIZATION_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_ORGANIZATION_ID = '22222222-2222-4222-8222-222222222222';
const REGISTRATION_NUMBER = 'RC/1234567';
const mockEnabledFlags = new Set<string>();
const mockFeatureChecks = jest.fn();
const mockRoleChecks = jest.fn();
let mockTenantRole = 'owner';

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
    req.tenant = {
      id: ORGANIZATION_ID,
      name: 'Ada Farms',
      type: 'farm_business',
      jurisdiction: 'NG',
      role: mockTenantRole,
      permissions: [],
    };
    return next();
  },
  requireTenantRole: (roles: string[]) => (req: any, res: any, next: any) => {
    mockRoleChecks(roles, req.tenant?.role);
    if (!roles.includes(req.tenant?.role)) {
      return res.status(403).json({ success: false, error: 'TENANT_ROLE_REQUIRED' });
    }
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

jest.mock('../domains/organizations/organizationVerificationService.js', () => ({
  organizationVerificationService: {
    start: jest.fn(),
    getCurrent: jest.fn(),
  },
}));

const app = express();
app.use(express.json());
app.use('/api/organizations', organizationRoutes);

const submit = (idempotencyKey = 'organization-command-1') => request(app)
  .post('/api/organizations/current/verification')
  .set('Authorization', 'Bearer valid-token')
  .set('X-Organization-Id', ORGANIZATION_ID)
  .set('Idempotency-Key', idempotencyKey);

const validBody = {
  registrationType: 'cac_rc',
  registrationNumber: REGISTRATION_NUMBER,
  authorityAttested: true,
};

describe('mounted organization verification route API contract', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockEnabledFlags.clear();
    mockEnabledFlags.add('integration.organization_verification');
    mockTenantRole = 'owner';
    (organizationVerificationService.start as jest.Mock).mockResolvedValue({
      id: 'request-1',
      organizationId: ORGANIZATION_ID,
      registrationType: 'cac_rc',
      maskedRegistration: 'RC/****4567',
      state: 'verified',
    } as never);
    (organizationVerificationService.getCurrent as jest.Mock).mockResolvedValue({
      id: 'request-1',
      organizationId: ORGANIZATION_ID,
      maskedRegistration: 'RC/****4567',
      state: 'verified',
    } as never);
  });

  it('requires authentication before tenant, role, or feature evaluation', async () => {
    await request(app)
      .post('/api/organizations/current/verification')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .set('Idempotency-Key', 'organization-command-1')
      .send(validBody)
      .expect(401, { success: false, error: 'Access token required' });

    expect(mockRoleChecks).not.toHaveBeenCalled();
    expect(mockFeatureChecks).not.toHaveBeenCalled();
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it('rejects an organization outside the authenticated membership boundary', async () => {
    const response = await request(app)
      .post('/api/organizations/current/verification')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', OTHER_ORGANIZATION_ID)
      .set('Idempotency-Key', 'organization-command-1')
      .send(validBody)
      .expect(403);

    expect(response.body.error).toBe('TENANT_ACCESS_DENIED');
    expect(mockRoleChecks).not.toHaveBeenCalled();
    expect(mockFeatureChecks).not.toHaveBeenCalled();
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it.each(['member', 'viewer'])('requires owner or admin before evaluating the submission flag: %s', async (role) => {
    mockTenantRole = role;

    await submit().send(validBody).expect(403, {
      success: false,
      error: 'TENANT_ROLE_REQUIRED',
    });

    expect(mockFeatureChecks).not.toHaveBeenCalled();
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it.each(['owner', 'admin'])('allows an authorized %s to submit when the feature is enabled', async (role) => {
    mockTenantRole = role;

    await submit().send(validBody).expect(202);

    expect(mockFeatureChecks).toHaveBeenCalledWith('integration.organization_verification', ORGANIZATION_ID);
    expect(organizationVerificationService.start).toHaveBeenCalledWith(expect.objectContaining({
      organizationId: ORGANIZATION_ID,
      userId: 'user-1',
      registrationNumber: REGISTRATION_NUMBER,
      idempotencyKey: 'organization-command-1',
    }));
  });

  it('fails closed for submissions when the organization-verification flag is disabled', async () => {
    mockEnabledFlags.clear();

    const response = await submit().send(validBody).expect(503);

    expect(response.body).toEqual(expect.objectContaining({
      success: false,
      error: 'FEATURE_DISABLED',
      feature: 'integration.organization_verification',
    }));
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it('rejects status reads outside the authenticated membership boundary', async () => {
    const response = await request(app)
      .get('/api/organizations/current/verification')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', OTHER_ORGANIZATION_ID)
      .expect(403);

    expect(response.body.error).toBe('TENANT_ACCESS_DENIED');
    expect(organizationVerificationService.getCurrent).not.toHaveBeenCalled();
  });

  it('keeps tenant-scoped status readable to a member while submission is disabled', async () => {
    mockEnabledFlags.clear();
    mockTenantRole = 'member';

    const response = await request(app)
      .get('/api/organizations/current/verification')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .expect(200);

    expect(mockRoleChecks).not.toHaveBeenCalled();
    expect(mockFeatureChecks).not.toHaveBeenCalled();
    expect(organizationVerificationService.getCurrent).toHaveBeenCalledWith(ORGANIZATION_ID, 'user-1');
    expect(response.body.data).toEqual(expect.objectContaining({ maskedRegistration: 'RC/****4567' }));
    expect(JSON.stringify(response.body)).not.toContain(REGISTRATION_NUMBER);
  });

  it.each([
    {},
    { registrationType: 'cac_rc', registrationNumber: REGISTRATION_NUMBER },
    { registrationType: 'invalid', registrationNumber: REGISTRATION_NUMBER, authorityAttested: true },
    { registrationType: 'cac_rc', registrationNumber: 'RC 123', authorityAttested: true },
  ])('rejects malformed submission input without echoing registration data: %j', async (body) => {
    const response = await submit().send(body).expect(400);

    expect(response.body).toEqual({
      success: false,
      error: 'VALIDATION_ERROR',
      message: 'Organization verification request is invalid',
    });
    if ('registrationNumber' in body) {
      expect(JSON.stringify(response.body)).not.toContain(String(body.registrationNumber));
    }
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it.each([
    'short',
    'x'.repeat(161),
    REGISTRATION_NUMBER,
    'request-' + REGISTRATION_NUMBER,
    'request-rc-123-4567',
  ])('rejects a supplied non-opaque or unbounded idempotency key: %j', async (idempotencyKey) => {
    const response = await submit(idempotencyKey).send(validBody).expect(400);

    expect(response.body).toEqual(expect.objectContaining({
      success: false,
      error: 'INVALID_IDEMPOTENCY_KEY',
    }));
    expect(response.body.message).toMatch(/opaque|non-whitespace/);
    expect(organizationVerificationService.start).not.toHaveBeenCalled();
  });

  it('creates an opaque random key when the client omits one', async () => {
    await request(app)
      .post('/api/organizations/current/verification')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .send(validBody)
      .expect(202);

    const command = (organizationVerificationService.start as jest.Mock).mock.calls[0][0] as any;
    expect(command.idempotencyKey).toMatch(/^organization-verification-[0-9a-f-]{36}$/);
    expect(command.idempotencyKey).not.toContain('1234567');
  });

  it('forwards identical tenant-scoped facts on an exact client replay', async () => {
    await submit().send(validBody).expect(202);
    await submit().send(validBody).expect(202);

    expect((organizationVerificationService.start as jest.Mock).mock.calls.map(([command]: any[]) => ({
      organizationId: command.organizationId,
      userId: command.userId,
      registrationNumber: command.registrationNumber,
      idempotencyKey: command.idempotencyKey,
    }))).toEqual([
      {
        organizationId: ORGANIZATION_ID,
        userId: 'user-1',
        registrationNumber: REGISTRATION_NUMBER,
        idempotencyKey: 'organization-command-1',
      },
      {
        organizationId: ORGANIZATION_ID,
        userId: 'user-1',
        registrationNumber: REGISTRATION_NUMBER,
        idempotencyKey: 'organization-command-1',
      },
    ]);
  });

  it('redacts unexpected provider and database errors from submission responses', async () => {
    (organizationVerificationService.start as jest.Mock).mockRejectedValue(
      new Error('provider.internal token=secret raw-registration=' + REGISTRATION_NUMBER) as never,
    );

    const response = await submit().send(validBody).expect(422);

    expect(response.body).toEqual({
      success: false,
      error: 'ORGANIZATION_VERIFICATION_FAILED',
      message: 'Organization verification could not be completed',
    });
    expect(JSON.stringify(response.body)).not.toContain('provider.internal');
    expect(JSON.stringify(response.body)).not.toContain('secret');
    expect(JSON.stringify(response.body)).not.toContain(REGISTRATION_NUMBER);
  });

  it('redacts unexpected database errors from status responses', async () => {
    (organizationVerificationService.getCurrent as jest.Mock).mockRejectedValue(
      new Error('postgres host=db.internal registration=' + REGISTRATION_NUMBER) as never,
    );

    const response = await request(app)
      .get('/api/organizations/current/verification')
      .set('Authorization', 'Bearer valid-token')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .expect(503);

    expect(response.body).toEqual({
      success: false,
      error: 'ORGANIZATION_VERIFICATION_UNAVAILABLE',
    });
    expect(JSON.stringify(response.body)).not.toContain('db.internal');
    expect(JSON.stringify(response.body)).not.toContain(REGISTRATION_NUMBER);
  });
});
