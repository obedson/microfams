import { FEATURE_FLAG_CATALOG, FEATURE_FLAGS } from '../../config/featureFlagCatalog.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import {
  FeatureFlagEnvironment,
  FeatureFlagScope,
} from '../../types/featureFlags.js';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { SupabaseFeatureFlagAdministrationRepository } from './featureFlagAdministrationRepository.js';
import {
  FeatureFlagAdministrationRepository,
  FeatureFlagOverrideDecision,
} from './featureFlagAdministrationTypes.js';

const reasonPattern = /^[A-Za-z0-9][A-Za-z0-9 _.:/#-]{7,499}$/;
const incidentPattern = /^[A-Za-z0-9][A-Za-z0-9_.:/#-]{2,119}$/;

export class FeatureFlagAdministrationError extends Error {
  constructor(readonly code: string, readonly status: number, message = code) {
    super(message);
  }
}

const commandFailure = () => new FeatureFlagAdministrationError(
  'FEATURE_FLAG_ADMINISTRATION_COMMAND_FAILED',
  409,
  'The feature flag command could not be completed',
);

const normalizeReason = (reason: string): string => {
  const normalized = reason.trim();
  if (!reasonPattern.test(normalized)) {
    throw new FeatureFlagAdministrationError('INVALID_FEATURE_FLAG_REASON', 400);
  }
  return normalized;
};

const knownFeature = (key: string) => {
  const definition = FEATURE_FLAGS.get(key);
  if (!definition) throw new FeatureFlagAdministrationError('FEATURE_FLAG_NOT_FOUND', 404);
  return definition;
};

const normalizedScopeId = (scopeType: FeatureFlagScope, scopeId?: string): string | null => {
  const normalized = scopeId?.trim() || null;
  if (scopeType === 'global' && normalized !== null) {
    throw new FeatureFlagAdministrationError('GLOBAL_SCOPE_ID_MUST_BE_EMPTY', 400);
  }
  if (scopeType !== 'global' && normalized === null) {
    throw new FeatureFlagAdministrationError('FEATURE_FLAG_SCOPE_ID_REQUIRED', 400);
  }
  return normalized;
};
const validatedConfig = (candidate?: Record<string, unknown>): Record<string, unknown> => {
  const config = candidate ?? {};
  if (!config || Array.isArray(config) || typeof config !== 'object') {
    throw new FeatureFlagAdministrationError('INVALID_FEATURE_FLAG_CONFIG', 400);
  }
  let serialized: string;
  try {
    serialized = JSON.stringify(config);
  } catch {
    throw new FeatureFlagAdministrationError('INVALID_FEATURE_FLAG_CONFIG', 400);
  }
  if (serialized.length > 16_384) {
    throw new FeatureFlagAdministrationError('INVALID_FEATURE_FLAG_CONFIG', 400);
  }
  const containsSecretKey = (value: unknown): boolean => value !== null && typeof value === 'object'
    && Object.entries(value).some(([key, nested]) => {
      const normalized = key.toLowerCase().replace(/[^a-z]/g, '');
      return ['secret', 'password', 'token', 'credential', 'privatekey', 'apikey']
        .some((suffix) => normalized.endsWith(suffix)) || containsSecretKey(nested);
    });
  if (containsSecretKey(config)) {
    throw new FeatureFlagAdministrationError('FEATURE_FLAG_CONFIG_MUST_NOT_CONTAIN_SECRETS', 400);
  }
  return config;
};

export class FeatureFlagAdministrationService {
  constructor(
    private readonly repository: FeatureFlagAdministrationRepository,
    private readonly evaluator: Pick<FeatureFlagService, 'evaluate'>,
  ) {}

  listCatalog() {
    return FEATURE_FLAG_CATALOG;
  }

  evaluate(
    key: string,
    context: {
      environment: FeatureFlagEnvironment;
      tenantId?: string;
      jurisdiction?: string;
      actorId?: string;
    },
  ) {
    knownFeature(key);
    return this.evaluator.evaluate(key, context);
  }

  async proposeOverride(input: {
    actorId: string;
    featureKey: string;
    scopeType: FeatureFlagScope;
    scopeId?: string;
    environment: FeatureFlagEnvironment | 'all';
    enabled: boolean;
    config?: Record<string, unknown>;
    reason: string;
    effectiveFrom?: string;
    effectiveUntil?: string;
  }) {
    const definition = knownFeature(input.featureKey);
    const reason = normalizeReason(input.reason);
    const config = validatedConfig(input.config);

    const effectiveFrom = input.effectiveFrom ?? new Date().toISOString();
    const start = new Date(effectiveFrom);
    const end = input.effectiveUntil ? new Date(input.effectiveUntil) : null;
    if (Number.isNaN(start.getTime()) || (end && (Number.isNaN(end.getTime()) || end <= start))) {
      throw new FeatureFlagAdministrationError('INVALID_FEATURE_FLAG_WINDOW', 400);
    }

    const requiresApproval = definition.risk !== 'standard';
    try {
      return await this.repository.createOverride({
        featureKey: input.featureKey,
        scopeType: input.scopeType,
        scopeId: normalizedScopeId(input.scopeType, input.scopeId),
        environment: input.environment,
        enabled: input.enabled,
        config,
        reason,
        status: requiresApproval ? 'pending' : 'approved',
        effectiveFrom: start.toISOString(),
        effectiveUntil: end?.toISOString() ?? null,
        createdBy: input.actorId,
        approvedBy: requiresApproval ? null : input.actorId,
        decidedBy: requiresApproval ? null : input.actorId,
      });
    } catch (error) {
      if (error instanceof FeatureFlagAdministrationError) throw error;
      throw commandFailure();
    }
  }

  async decideOverride(
    actorId: string,
    overrideId: string,
    decision: FeatureFlagOverrideDecision,
    reason: string,
  ) {
    const normalizedReason = normalizeReason(reason);
    try {
      const override = await this.repository.getOverride(overrideId);
      if (!override) throw new FeatureFlagAdministrationError('FEATURE_FLAG_OVERRIDE_NOT_FOUND', 404);
      if (override.status !== 'pending') {
        throw new FeatureFlagAdministrationError('FEATURE_FLAG_OVERRIDE_NOT_PENDING', 409);
      }
      if (override.createdBy === actorId) {
        throw new FeatureFlagAdministrationError('FEATURE_FLAG_MAKER_CHECKER_REQUIRED', 409);
      }
      return await this.repository.decideOverride(overrideId, actorId, decision, normalizedReason);
    } catch (error) {
      if (error instanceof FeatureFlagAdministrationError) throw error;
      throw commandFailure();
    }
  }

  async setEmergencyStop(input: {
    actorId: string;
    featureKey: string;
    disabled: boolean;
    reason: string;
    incidentReference: string;
  }) {
    knownFeature(input.featureKey);
    const reason = normalizeReason(input.reason);
    const incidentReference = input.incidentReference.trim();
    if (!incidentPattern.test(incidentReference)) {
      throw new FeatureFlagAdministrationError('INVALID_INCIDENT_REFERENCE', 400);
    }
    try {
      await this.repository.setEmergencyStop(
        input.featureKey,
        input.actorId,
        input.disabled,
        reason,
        incidentReference,
      );
      return { featureKey: input.featureKey, emergencyDisabled: input.disabled };
    } catch {
      throw commandFailure();
    }
  }

  async listAudit(featureKey?: string, limit = 100) {
    if (featureKey) knownFeature(featureKey);
    try {
      return await this.repository.listAudit(featureKey, Math.min(Math.max(limit, 1), 200));
    } catch {
      throw commandFailure();
    }
  }
}

export const featureFlagAdministrationService = new FeatureFlagAdministrationService(
  new SupabaseFeatureFlagAdministrationRepository(),
  new FeatureFlagService(new SupabaseFeatureFlagRepository()),
);
