import express from 'express';
import request from 'supertest';
import { createResolveTenant, TenantRequest } from '../middleware/tenant.js';
import { TenantResolutionError } from '../services/tenantService.js';
import { TenantContext } from '../types/tenant.js';

const ORGANIZATION_ID = '11111111-1111-4111-8111-111111111111';
const tenant: TenantContext = {
  id: ORGANIZATION_ID,
  name: 'Growers Cooperative',
  slug: 'growers-cooperative',
  type: 'cooperative',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-1',
  userId: 'user-1',
  role: 'member',
  permissions: [],
};

const createApp = (resolve: jest.Mock) => {
  const app = express();
  app.get(
    '/protected',
    (req: TenantRequest, _res, next) => {
      req.user = { id: 'user-1' } as TenantRequest['user'];
      next();
    },
    createResolveTenant({ resolve }),
    (req: TenantRequest, res) => res.json({
      success: true,
      organizationId: req.tenant!.id,
    }),
  );
  return app;
};

describe('tenant selection API contract', () => {
  it('auto-selects the only active membership when the selector is omitted', async () => {
    const resolve = jest.fn().mockResolvedValue(tenant);

    await request(createApp(resolve))
      .get('/protected')
      .expect(200, { success: true, organizationId: ORGANIZATION_ID });

    expect(resolve).toHaveBeenCalledWith('user-1', undefined);
  });

  it('requires an explicit selector when multiple memberships are active', async () => {
    const resolve = jest.fn().mockRejectedValue(new TenantResolutionError(
      'TENANT_SELECTION_REQUIRED',
      400,
      'Select an organization for this request.',
    ));

    await request(createApp(resolve))
      .get('/protected')
      .expect(400, {
        success: false,
        error: 'TENANT_SELECTION_REQUIRED',
        message: 'Select an organization for this request.',
      });
  });

  it('rejects a forged organization selector without exposing membership details', async () => {
    const resolve = jest.fn().mockRejectedValue(new TenantResolutionError(
      'TENANT_ACCESS_DENIED',
      403,
      'You do not have active access to that organization.',
    ));

    await request(createApp(resolve))
      .get('/protected')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .expect(403, {
        success: false,
        error: 'TENANT_ACCESS_DENIED',
        message: 'You do not have active access to that organization.',
      });

    expect(resolve).toHaveBeenCalledWith('user-1', ORGANIZATION_ID);
  });

  it('uses the same denial contract for suspended membership or organization access', async () => {
    const resolve = jest.fn().mockRejectedValue(new TenantResolutionError(
      'TENANT_ACCESS_DENIED',
      403,
      'You do not have active access to that organization.',
    ));

    await request(createApp(resolve))
      .get('/protected')
      .set('X-Organization-Id', ORGANIZATION_ID)
      .expect(403, {
        success: false,
        error: 'TENANT_ACCESS_DENIED',
        message: 'You do not have active access to that organization.',
      });
  });

  it.each(['', 'not-a-uuid', '  '])(
    'rejects a present malformed selector before tenant resolution: %j',
    async (selector) => {
      const resolve = jest.fn();

      await request(createApp(resolve))
        .get('/protected')
        .set('X-Organization-Id', selector)
        .expect(400, {
          success: false,
          error: 'INVALID_TENANT_SELECTION',
        });

      expect(resolve).not.toHaveBeenCalled();
    },
  );

  it('rejects users without any active membership', async () => {
    const resolve = jest.fn().mockRejectedValue(new TenantResolutionError(
      'TENANT_MEMBERSHIP_REQUIRED',
      403,
      'An active organization membership is required.',
    ));

    await request(createApp(resolve))
      .get('/protected')
      .expect(403, {
        success: false,
        error: 'TENANT_MEMBERSHIP_REQUIRED',
        message: 'An active organization membership is required.',
      });
  });
});
