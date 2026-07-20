import { NextFunction, Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { createRequireFeature } from '../middleware/requireFeature.js';
import { FeatureFlagDecision } from '../types/featureFlags.js';

const response = () => {
  const res = {
    locals: {},
    setHeader: jest.fn(),
    status: jest.fn(),
    json: jest.fn(),
  } as unknown as Response;
  (res.status as jest.Mock).mockReturnValue(res);
  (res.json as jest.Mock).mockReturnValue(res);
  return res;
};

const evaluator = (decision: FeatureFlagDecision) => ({
  evaluate: jest.fn().mockResolvedValue(decision),
});

describe('requireFeature middleware', () => {
  it('rejects unregistered keys at application startup', () => {
    expect(() => createRequireFeature(evaluator({
      key: 'unused', enabled: false, config: {}, source: 'unknown', reason: 'unused',
    }))('unregistered')).toThrow('Feature flag is not registered');
  });

  it('returns a controlled response when the feature is disabled', async () => {
    const featureService = evaluator({
      key: 'integration.weather', enabled: false, config: {}, source: 'default', reason: 'disabled',
    });
    const middleware = createRequireFeature(featureService)('integration.weather');
    const req = {
      user: { id: 'user-1' },
      tenant: { id: 'tenant-1', jurisdiction: 'NG' },
    } as unknown as TenantRequest;
    const res = response();
    const next = jest.fn() as NextFunction;

    await middleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ error: 'FEATURE_DISABLED', feature: 'integration.weather' }));
    expect(next).not.toHaveBeenCalled();
    expect(featureService.evaluate).toHaveBeenCalledWith('integration.weather', expect.objectContaining({
      actorId: 'user-1', tenantId: 'tenant-1', jurisdiction: 'NG',
    }));
  });

  it('passes the effective decision to downstream handlers when enabled', async () => {
    const decision: FeatureFlagDecision = {
      key: 'integration.weather', enabled: true, config: { provider: 'mock' }, source: 'override', reason: 'enabled',
    };
    const middleware = createRequireFeature(evaluator(decision))('integration.weather');
    const res = response();
    const next = jest.fn() as NextFunction;

    await middleware({ user: { id: 'user-1' } } as TenantRequest, res, next);

    expect(res.locals.feature).toEqual(decision);
    expect(next).toHaveBeenCalledTimes(1);
  });
});
