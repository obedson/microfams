import { jest } from '@jest/globals';
import { featureFlagAdministrationController } from '../controllers/featureFlagAdministrationController.js';
import {
  FeatureFlagAdministrationError,
  featureFlagAdministrationService,
} from '../domains/platform/featureFlagAdministrationService.js';

jest.mock('../domains/platform/featureFlagAdministrationService.js', () => {
  class MockFeatureFlagAdministrationError extends Error {
    constructor(readonly code: string, readonly status: number, message = code) {
      super(message);
    }
  }
  return {
    FeatureFlagAdministrationError: MockFeatureFlagAdministrationError,
    featureFlagAdministrationService: {
      listCatalog: jest.fn(),
      evaluate: jest.fn(),
      proposeOverride: jest.fn(),
      decideOverride: jest.fn(),
      setEmergencyStop: jest.fn(),
      listAudit: jest.fn(),
    },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('feature flag administration API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('proposes a tenant and environment scoped override as the authenticated platform admin', async () => {
    (featureFlagAdministrationService.proposeOverride as jest.Mock).mockResolvedValue({
      id: '00000000-0000-4000-8000-000000000301',
      status: 'pending',
    } as never);
    const res = response();

    await featureFlagAdministrationController.proposeOverride({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { key: 'integration.weather' },
      body: {
        scopeType: 'tenant',
        scopeId: 'tenant-1',
        environment: 'staging',
        enabled: true,
        config: { provider: 'sandbox' },
        reason: 'Enable provider after sandbox verification',
      },
    } as any, res);

    expect(featureFlagAdministrationService.proposeOverride).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: '00000000-0000-4000-8000-000000000201',
        featureKey: 'integration.weather',
        scopeId: 'tenant-1',
        environment: 'staging',
      }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires a bounded reason for every override', async () => {
    const res = response();
    await featureFlagAdministrationController.proposeOverride({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { key: 'integration.weather' },
      body: {
        scopeType: 'tenant',
        scopeId: 'tenant-1',
        environment: 'test',
        enabled: true,
        reason: 'short',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(featureFlagAdministrationService.proposeOverride).not.toHaveBeenCalled();
  });

  it('returns a controlled maker-checker conflict without persistence details', async () => {
    (featureFlagAdministrationService.decideOverride as jest.Mock).mockRejectedValue(
      new FeatureFlagAdministrationError(
        'FEATURE_FLAG_MAKER_CHECKER_REQUIRED',
        409,
        'FEATURE_FLAG_MAKER_CHECKER_REQUIRED',
      ) as never,
    );
    const res = response();

    await featureFlagAdministrationController.decideOverride({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { overrideId: '00000000-0000-4000-8000-000000000301' },
      body: {
        decision: 'approve',
        reason: 'Independently reviewed provider evidence',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0])).not.toContain('database');
  });

  it('requires an incident reference for emergency stop changes', async () => {
    const res = response();
    await featureFlagAdministrationController.setEmergencyStop({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { key: 'financial.payments.accept_new' },
      body: {
        disabled: true,
        reason: 'Stop new payments during provider incident',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(featureFlagAdministrationService.setEmergencyStop).not.toHaveBeenCalled();
  });
});
