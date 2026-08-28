import { FeatureFlagAdministrationService } from '../domains/platform/featureFlagAdministrationService.js';
import {
  FeatureFlagAdministrationRepository,
  FeatureFlagOverrideRecord,
} from '../domains/platform/featureFlagAdministrationTypes.js';

const override = (value: Partial<FeatureFlagOverrideRecord> = {}): FeatureFlagOverrideRecord => ({
  id: '00000000-0000-4000-8000-000000000301',
  featureKey: 'integration.weather',
  scopeType: 'tenant',
  scopeId: 'tenant-1',
  environment: 'test',
  enabled: true,
  config: {},
  reason: 'Enable approved weather provider',
  status: 'pending',
  effectiveFrom: '2026-01-01T00:00:00.000Z',
  effectiveUntil: null,
  createdBy: '00000000-0000-4000-8000-000000000201',
  approvedBy: null,
  decidedBy: null,
  createdAt: '2026-01-01T00:00:00.000Z',
  decisionAt: null,
  decisionReason: null,
  ...value,
});

const repository = (): jest.Mocked<FeatureFlagAdministrationRepository> => ({
  createOverride: jest.fn(),
  getOverride: jest.fn(),
  decideOverride: jest.fn(),
  setEmergencyStop: jest.fn(),
  listAudit: jest.fn(),
});

const evaluator = { evaluate: jest.fn() };

describe('feature flag administration service', () => {
  beforeEach(() => jest.clearAllMocks());

  it('auto-approves standard changes but keeps provider changes pending', async () => {
    const repo = repository();
    repo.createOverride
      .mockResolvedValueOnce(override({ featureKey: 'intelligence.agronomic_recommendations', status: 'approved' }))
      .mockResolvedValueOnce(override());
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await service.proposeOverride({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'intelligence.agronomic_recommendations',
      scopeType: 'tenant',
      scopeId: 'tenant-1',
      environment: 'test',
      enabled: true,
      reason: 'Enable reviewed agronomic recommendations',
    });
    await service.proposeOverride({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'integration.weather',
      scopeType: 'tenant',
      scopeId: 'tenant-1',
      environment: 'test',
      enabled: true,
      reason: 'Enable approved weather provider',
    });

    expect(repo.createOverride.mock.calls[0][0]).toMatchObject({
      status: 'approved',
      approvedBy: '00000000-0000-4000-8000-000000000201',
    });
    expect(repo.createOverride.mock.calls[1][0]).toMatchObject({
      status: 'pending',
      approvedBy: null,
    });
  });

  it('requires a different actor to approve a regulated or provider override', async () => {
    const repo = repository();
    repo.getOverride.mockResolvedValue(override());
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await expect(service.decideOverride(
      '00000000-0000-4000-8000-000000000201',
      '00000000-0000-4000-8000-000000000301',
      'approve',
      'Independently reviewed provider evidence',
    )).rejects.toMatchObject({ code: 'FEATURE_FLAG_MAKER_CHECKER_REQUIRED', status: 409 });
    expect(repo.decideOverride).not.toHaveBeenCalled();
  });

  it('records an independent approval decision', async () => {
    const repo = repository();
    repo.getOverride.mockResolvedValue(override());
    repo.decideOverride.mockResolvedValue(override({
      status: 'approved',
      approvedBy: '00000000-0000-4000-8000-000000000202',
      decidedBy: '00000000-0000-4000-8000-000000000202',
    }));
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await service.decideOverride(
      '00000000-0000-4000-8000-000000000202',
      '00000000-0000-4000-8000-000000000301',
      'approve',
      'Independently reviewed provider evidence',
    );

    expect(repo.decideOverride).toHaveBeenCalledWith(
      '00000000-0000-4000-8000-000000000301',
      '00000000-0000-4000-8000-000000000202',
      'approve',
      'Independently reviewed provider evidence',
    );
  });

  it('rejects invalid scope and effective windows before persistence', async () => {
    const repo = repository();
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await expect(service.proposeOverride({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'integration.weather',
      scopeType: 'global',
      scopeId: 'tenant-1',
      environment: 'test',
      enabled: true,
      reason: 'Enable approved weather provider',
    })).rejects.toMatchObject({ code: 'GLOBAL_SCOPE_ID_MUST_BE_EMPTY' });

    await expect(service.proposeOverride({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'integration.weather',
      scopeType: 'tenant',
      scopeId: 'tenant-1',
      environment: 'test',
      enabled: true,
      reason: 'Enable approved weather provider',
      effectiveFrom: '2026-06-02T00:00:00Z',
      effectiveUntil: '2026-06-01T00:00:00Z',
    })).rejects.toMatchObject({ code: 'INVALID_FEATURE_FLAG_WINDOW' });
    expect(repo.createOverride).not.toHaveBeenCalled();
  });

  it('rejects secret-bearing configuration before it can enter audit history', async () => {
    const repo = repository();
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await expect(service.proposeOverride({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'integration.weather',
      scopeType: 'tenant',
      scopeId: 'tenant-1',
      environment: 'test',
      enabled: true,
      config: {
        provider: 'sandbox',
        credentials: { apiKey: 'must-not-be-stored-here' },
      },
      reason: 'Enable approved weather provider',
    })).rejects.toMatchObject({ code: 'FEATURE_FLAG_CONFIG_MUST_NOT_CONTAIN_SECRETS' });

    expect(repo.createOverride).not.toHaveBeenCalled();
  });

  it('requires incident evidence for an emergency stop', async () => {
    const repo = repository();
    const service = new FeatureFlagAdministrationService(repo, evaluator as any);

    await expect(service.setEmergencyStop({
      actorId: '00000000-0000-4000-8000-000000000201',
      featureKey: 'financial.payments.accept_new',
      disabled: true,
      reason: 'Stop new payments during provider incident',
      incidentReference: '!',
    })).rejects.toMatchObject({ code: 'INVALID_INCIDENT_REFERENCE' });
    expect(repo.setEmergencyStop).not.toHaveBeenCalled();
  });
});
