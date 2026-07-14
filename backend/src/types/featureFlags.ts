export type FeatureFlagScope = 'global' | 'jurisdiction' | 'tenant' | 'actor';
export type FeatureFlagEnvironment = 'development' | 'test' | 'staging' | 'production';
export type FeatureFlagFailureMode = 'open' | 'closed';
export type FeatureFlagRisk = 'standard' | 'provider' | 'regulated';

export interface FeatureFlagDefinition {
  key: string;
  description: string;
  defaultEnabled: boolean;
  failureMode: FeatureFlagFailureMode;
  risk: FeatureFlagRisk;
  domain: string;
}

export interface FeatureFlagOverride {
  id: string;
  featureKey: string;
  scopeType: FeatureFlagScope;
  scopeId: string | null;
  environment: FeatureFlagEnvironment | 'all';
  enabled: boolean;
  config: Record<string, unknown>;
  effectiveFrom: string;
  effectiveUntil: string | null;
}

export interface FeatureFlagState {
  emergencyDisabled: boolean;
  overrides: FeatureFlagOverride[];
}

export interface FeatureFlagContext {
  environment: FeatureFlagEnvironment;
  tenantId?: string;
  jurisdiction?: string;
  actorId?: string;
  now?: Date;
}

export interface FeatureFlagDecision {
  key: string;
  enabled: boolean;
  config: Record<string, unknown>;
  source: 'emergency_stop' | 'override' | 'default' | 'failure_mode' | 'unknown';
  matchedScope?: FeatureFlagScope;
  reason: string;
}

export interface FeatureFlagRepository {
  getState(featureKey: string): Promise<FeatureFlagState>;
}
