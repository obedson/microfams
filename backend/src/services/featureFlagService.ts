import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import {
  FeatureFlagContext,
  FeatureFlagDecision,
  FeatureFlagOverride,
  FeatureFlagRepository,
  FeatureFlagScope,
} from '../types/featureFlags.js';

const SCOPE_PRIORITY: Record<FeatureFlagScope, number> = {
  global: 0,
  jurisdiction: 1,
  tenant: 2,
  actor: 3,
};

export class FeatureFlagService {
  constructor(private readonly repository: FeatureFlagRepository) {}

  async evaluate(key: string, context: FeatureFlagContext): Promise<FeatureFlagDecision> {
    const definition = FEATURE_FLAGS.get(key);
    if (!definition) {
      return { key, enabled: false, config: {}, source: 'unknown', reason: 'Unknown features fail closed.' };
    }

    let state;
    try {
      state = await this.repository.getState(key);
    } catch {
      return {
        key,
        enabled: definition.failureMode === 'open',
        config: {},
        source: 'failure_mode',
        reason: `Flag storage unavailable; ${definition.failureMode === 'open' ? 'continuing required servicing' : 'blocking new exposure'}.`,
      };
    }

    if (state.emergencyDisabled) {
      return { key, enabled: false, config: {}, source: 'emergency_stop', reason: 'Global emergency stop is active.' };
    }

    const now = context.now ?? new Date();
    const matches = state.overrides
      .filter((override) => this.matches(override, context, now))
      .sort((left, right) => (
        SCOPE_PRIORITY[left.scopeType] - SCOPE_PRIORITY[right.scopeType]
        || new Date(left.effectiveFrom).getTime() - new Date(right.effectiveFrom).getTime()
      ));

    const config = matches.reduce<Record<string, unknown>>(
      (result, override) => ({ ...result, ...override.config }),
      {},
    );
    const winner = matches.at(-1);

    if (winner) {
      return {
        key,
        enabled: winner.enabled,
        config,
        source: 'override',
        matchedScope: winner.scopeType,
        reason: `Matched active ${winner.scopeType} override.`,
      };
    }

    return {
      key,
      enabled: definition.defaultEnabled,
      config: {},
      source: 'default',
      reason: 'No active override matched; catalog default applied.',
    };
  }

  private matches(override: FeatureFlagOverride, context: FeatureFlagContext, now: Date): boolean {
    if (override.environment !== 'all' && override.environment !== context.environment) return false;
    if (new Date(override.effectiveFrom) > now) return false;
    if (override.effectiveUntil && new Date(override.effectiveUntil) <= now) return false;

    switch (override.scopeType) {
      case 'global': return override.scopeId === null;
      case 'jurisdiction': return Boolean(context.jurisdiction && override.scopeId === context.jurisdiction);
      case 'tenant': return Boolean(context.tenantId && override.scopeId === context.tenantId);
      case 'actor': return Boolean(context.actorId && override.scopeId === context.actorId);
    }
  }
}
