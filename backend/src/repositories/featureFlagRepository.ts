import { supabase } from '../utils/supabase.js';
import {
  FeatureFlagOverride,
  FeatureFlagRepository,
  FeatureFlagState,
} from '../types/featureFlags.js';

interface OverrideRow {
  id: string;
  feature_key: string;
  scope_type: FeatureFlagOverride['scopeType'];
  scope_id: string | null;
  environment: FeatureFlagOverride['environment'];
  enabled: boolean;
  config: Record<string, unknown> | null;
  effective_from: string;
  effective_until: string | null;
}

export class SupabaseFeatureFlagRepository implements FeatureFlagRepository {
  async getState(featureKey: string): Promise<FeatureFlagState> {
    const [definitionResult, overrideResult] = await Promise.all([
      supabase
        .from('feature_flags')
        .select('emergency_disabled')
        .eq('key', featureKey)
        .maybeSingle(),
      supabase
        .from('feature_flag_overrides')
        .select('id, feature_key, scope_type, scope_id, environment, enabled, config, effective_from, effective_until')
        .eq('feature_key', featureKey),
    ]);

    if (definitionResult.error) throw definitionResult.error;
    if (overrideResult.error) throw overrideResult.error;

    return {
      emergencyDisabled: definitionResult.data?.emergency_disabled ?? false,
      overrides: ((overrideResult.data ?? []) as OverrideRow[]).map((row) => ({
        id: row.id,
        featureKey: row.feature_key,
        scopeType: row.scope_type,
        scopeId: row.scope_id,
        environment: row.environment,
        enabled: row.enabled,
        config: row.config ?? {},
        effectiveFrom: row.effective_from,
        effectiveUntil: row.effective_until,
      })),
    };
  }
}
