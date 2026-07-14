import { FeatureFlagService } from '../services/featureFlagService.js';
import { FeatureFlagRepository, FeatureFlagState } from '../types/featureFlags.js';

const state = (value: Partial<FeatureFlagState> = {}): FeatureFlagState => ({
  emergencyDisabled: false,
  overrides: [],
  ...value,
});

const repository = (value: FeatureFlagState): FeatureFlagRepository => ({
  getState: jest.fn().mockResolvedValue(value),
});

describe('FeatureFlagService', () => {
  const context = { environment: 'test' as const, tenantId: 'tenant-1', jurisdiction: 'NG', actorId: 'user-1' };

  it('fails closed for unknown features', async () => {
    const service = new FeatureFlagService(repository(state()));
    await expect(service.evaluate('not.registered', context)).resolves.toMatchObject({ enabled: false, source: 'unknown' });
  });

  it('blocks new regulated exposure when flag storage is unavailable', async () => {
    const service = new FeatureFlagService({ getState: jest.fn().mockRejectedValue(new Error('offline')) });
    await expect(service.evaluate('financial.loans.originate', context)).resolves.toMatchObject({
      enabled: false,
      source: 'failure_mode',
    });
  });

  it('continues required servicing when flag storage is unavailable', async () => {
    const service = new FeatureFlagService({ getState: jest.fn().mockRejectedValue(new Error('offline')) });
    await expect(service.evaluate('financial.loans.service_existing', context)).resolves.toMatchObject({
      enabled: true,
      source: 'failure_mode',
    });
  });

  it('applies the most specific active override and merges layered configuration', async () => {
    const service = new FeatureFlagService(repository(state({ overrides: [
      { id: 'global', featureKey: 'integration.weather', scopeType: 'global', scopeId: null, environment: 'all', enabled: false, config: { timeout: 5 }, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: null },
      { id: 'tenant', featureKey: 'integration.weather', scopeType: 'tenant', scopeId: 'tenant-1', environment: 'test', enabled: true, config: { provider: 'mock' }, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: null },
      { id: 'other', featureKey: 'integration.weather', scopeType: 'tenant', scopeId: 'tenant-2', environment: 'test', enabled: true, config: { provider: 'wrong' }, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: null },
    ] })));

    await expect(service.evaluate('integration.weather', context)).resolves.toMatchObject({
      enabled: true,
      source: 'override',
      matchedScope: 'tenant',
      config: { timeout: 5, provider: 'mock' },
    });
  });

  it('ignores expired overrides', async () => {
    const service = new FeatureFlagService(repository(state({ overrides: [
      { id: 'expired', featureKey: 'integration.sms', scopeType: 'global', scopeId: null, environment: 'all', enabled: true, config: {}, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: '2021-01-01T00:00:00Z' },
    ] })));

    await expect(service.evaluate('integration.sms', { ...context, now: new Date('2022-01-01T00:00:00Z') })).resolves.toMatchObject({ enabled: false, source: 'default' });
  });

  it('uses the newest effective override when the same scope has changed', async () => {
    const service = new FeatureFlagService(repository(state({ overrides: [
      { id: 'new', featureKey: 'integration.sms', scopeType: 'tenant', scopeId: 'tenant-1', environment: 'test', enabled: true, config: { provider: 'new' }, effectiveFrom: '2024-01-01T00:00:00Z', effectiveUntil: null },
      { id: 'old', featureKey: 'integration.sms', scopeType: 'tenant', scopeId: 'tenant-1', environment: 'test', enabled: false, config: { provider: 'old' }, effectiveFrom: '2023-01-01T00:00:00Z', effectiveUntil: null },
    ] })));

    await expect(service.evaluate('integration.sms', context)).resolves.toMatchObject({
      enabled: true,
      config: { provider: 'new' },
    });
  });

  it('lets the emergency stop override every scope', async () => {
    const service = new FeatureFlagService(repository(state({ emergencyDisabled: true })));
    await expect(service.evaluate('financial.payments.service_existing', context)).resolves.toMatchObject({
      enabled: false,
      source: 'emergency_stop',
    });
  });
});
