import { FeatureFlagService } from '../services/featureFlagService.js';
import { FeatureFlagRepository } from '../types/featureFlags.js';

describe('V1 feature-flag matrix', () => {
  const context = { environment: 'test' as const, tenantId: 'tenant-1', jurisdiction: 'NG', actorId: 'user-1' };
  const repo = (state: any): FeatureFlagRepository => ({ getState: jest.fn().mockResolvedValue(state) });
  it.each([
    ['disabled by default', 'integration.ai_assistant', {}, false, 'default'],
    ['BVN progressive KYC disabled by default', 'integration.identity_bvn_verification', {}, false, 'default'],
    ['enabled by tenant override', 'integration.weather', { overrides: [{ id: 't', featureKey: 'integration.weather', scopeType: 'tenant', scopeId: 'tenant-1', environment: 'test', enabled: true, config: {}, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: null }] }, true, 'override'],
    ['misconfigured storage fails closed', 'integration.weather', null, false, 'failure_mode'],
    ['degraded provider remains a service decision', 'integration.weather', { overrides: [{ id: 't', featureKey: 'integration.weather', scopeType: 'tenant', scopeId: 'tenant-1', environment: 'test', enabled: false, config: { degraded: true }, effectiveFrom: '2020-01-01T00:00:00Z', effectiveUntil: null }] }, false, 'override'],
  ])('%s', async (_label, key, state, enabled, source) => {
    const repository = state === null ? { getState: jest.fn().mockRejectedValue(new Error('unavailable')) } : repo({ emergencyDisabled: false, overrides: [], ...state });
    await expect(new FeatureFlagService(repository).evaluate(key, context)).resolves.toMatchObject({ enabled, source });
  });
  it('emergency stop disables an otherwise enabled feature', async () => {
    await expect(new FeatureFlagService(repo({ emergencyDisabled: true, overrides: [] })).evaluate('integration.weather', context)).resolves.toMatchObject({ enabled: false, source: 'emergency_stop' });
  });
});
