import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const PROVIDER_CODE_PATTERN = /^[a-z][a-z0-9_.-]{1,63}$/;
const JURISDICTION_PATTERN = /^[A-Z]{2}$/;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;

export type SavingsProviderEnvironment = 'deterministic' | 'sandbox' | 'live';
export type SavingsCertificationEnvironment = Exclude<SavingsProviderEnvironment, 'deterministic'>;
export type SavingsCertificationScenario =
  | 'contribution_success'
  | 'contribution_duplicate'
  | 'contribution_failure'
  | 'standing_order_retry'
  | 'withdrawal_success'
  | 'withdrawal_failure'
  | 'provider_callback_replay'
  | 'reconciliation_zero_variance'
  | 'servicing_after_disable';

export const SAVINGS_CERTIFICATION_SCENARIOS: readonly SavingsCertificationScenario[] = [
  'contribution_success', 'contribution_duplicate', 'contribution_failure',
  'standing_order_retry', 'withdrawal_success', 'withdrawal_failure',
  'provider_callback_replay', 'reconciliation_zero_variance', 'servicing_after_disable',
] as const;

export interface CreateSavingsProviderCertificationCommand {
  organizationId: string;
  actorId: string;
  providerCode: string;
  providerLegalName: string;
  environment: SavingsCertificationEnvironment;
  jurisdiction: string;
  currency: string;
  version: number;
  configurationFingerprint: string;
  providerContractReference: string;
  credentialsValidationReference: string;
  webhookCertificationReference: string;
  settlementAccountReference: string;
  complianceNotesReference: string;
  threatModelReference: string;
  dataProtectionReviewReference: string;
  supportRunbookReference: string;
  reconciliationSignoffReference: string;
  limitsDisclosuresReference: string;
  operationalOwnerId: string;
  validUntil: string;
  idempotencyKey: string;
}

export interface RecordSavingsCertificationScenarioCommand {
  organizationId: string;
  actorId: string;
  certificationId: string;
  scenarioCode: SavingsCertificationScenario;
  attemptNumber: number;
  result: 'passed' | 'failed';
  unexplainedVarianceMinor: number;
  evidenceReference: string;
  evidenceSha256: string;
  startedAt: string;
  completedAt: string;
  idempotencyKey: string;
}

export interface SavingsCertificationTransitionCommand {
  organizationId: string;
  actorId: string;
  certificationId: string;
  reason: string;
  idempotencyKey: string;
}

export interface DecideSavingsCertificationCommand extends SavingsCertificationTransitionCommand {
  approve: boolean;
}

export interface SavingsProviderReadinessQuery {
  organizationId: string;
  actorId: string;
  providerCode: string;
  environment: SavingsCertificationEnvironment;
  jurisdiction: string;
  currency: string;
  configurationFingerprint: string;
}

export interface SavingsProviderReadiness {
  ready: boolean;
  organizationId: string;
  providerCode: string;
  environment: SavingsCertificationEnvironment;
  jurisdiction: string;
  currency: string;
  certificationId: string | null;
  certificationVersion: number | null;
  validUntil: string | null;
  liveActivationId: string | null;
  missing: string[];
}

export interface SavingsProviderCertificationGateway {
  create(command: CreateSavingsProviderCertificationCommand): Promise<unknown>;
  recordScenario(command: RecordSavingsCertificationScenarioCommand): Promise<unknown>;
  submit(command: SavingsCertificationTransitionCommand): Promise<unknown>;
  decide(command: DecideSavingsCertificationCommand): Promise<unknown>;
  list(organizationId: string, actorId: string): Promise<unknown[]>;
  readReadiness(query: SavingsProviderReadinessQuery): Promise<SavingsProviderReadiness>;
}

export class SavingsProviderCertificationError extends Error {
  constructor(message: string, readonly code = 'INVALID_SAVINGS_PROVIDER_CERTIFICATION') {
    super(message);
    this.name = 'SavingsProviderCertificationError';
  }
}

export class SavingsProviderConfigurationError extends Error {
  constructor(message: string, readonly code: string, readonly missing: string[] = []) {
    super(message);
    this.name = 'SavingsProviderConfigurationError';
  }
}

const assertUuid = (value: string, label: string) => {
  if (!UUID_PATTERN.test(value)) throw new SavingsProviderCertificationError(`${label} must be a valid UUID.`);
};

const assertReference = (value: string, label: string) => {
  if (value.trim().length < 8 || value.trim().length > 500) {
    throw new SavingsProviderCertificationError(`${label} must contain 8 to 500 characters.`);
  }
};

const assertIdempotencyKey = (value: string) => {
  if (value.length < 8 || value.length > 160) {
    throw new SavingsProviderCertificationError('Idempotency key must contain 8 to 160 characters.');
  }
};

const canonicalTime = (value: string, label: string) => {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString() !== value) {
    throw new SavingsProviderCertificationError(`${label} must be a canonical UTC ISO-8601 timestamp.`);
  }
  return parsed;
};

export class SupabaseSavingsProviderCertificationGateway implements SavingsProviderCertificationGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Savings provider certification storage returned no result.');
    return data;
  }

  create(command: CreateSavingsProviderCertificationCommand) {
    return this.rpc('create_savings_provider_certification', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_provider_code: command.providerCode, p_provider_legal_name: command.providerLegalName,
      p_environment: command.environment, p_jurisdiction: command.jurisdiction,
      p_currency: command.currency, p_version: command.version,
      p_configuration_fingerprint: command.configurationFingerprint,
      p_provider_contract_reference: command.providerContractReference,
      p_credentials_validation_reference: command.credentialsValidationReference,
      p_webhook_certification_reference: command.webhookCertificationReference,
      p_settlement_account_reference: command.settlementAccountReference,
      p_compliance_notes_reference: command.complianceNotesReference,
      p_threat_model_reference: command.threatModelReference,
      p_data_protection_review_reference: command.dataProtectionReviewReference,
      p_support_runbook_reference: command.supportRunbookReference,
      p_reconciliation_signoff_reference: command.reconciliationSignoffReference,
      p_limits_disclosures_reference: command.limitsDisclosuresReference,
      p_operational_owner: command.operationalOwnerId, p_valid_until: command.validUntil,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  recordScenario(command: RecordSavingsCertificationScenarioCommand) {
    return this.rpc('record_savings_provider_certification_scenario', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_certification: command.certificationId, p_scenario_code: command.scenarioCode,
      p_attempt_number: command.attemptNumber, p_result: command.result,
      p_unexplained_variance_minor: command.unexplainedVarianceMinor,
      p_evidence_reference: command.evidenceReference, p_evidence_sha256: command.evidenceSha256,
      p_started_at: command.startedAt,
      p_completed_at: command.completedAt, p_idempotency_key: command.idempotencyKey,
    });
  }

  submit(command: SavingsCertificationTransitionCommand) {
    return this.rpc('submit_savings_provider_certification', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_certification: command.certificationId, p_reason: command.reason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  decide(command: DecideSavingsCertificationCommand) {
    return this.rpc('decide_savings_provider_certification', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_certification: command.certificationId, p_approve: command.approve,
      p_reason: command.reason, p_idempotency_key: command.idempotencyKey,
    });
  }

  async list(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_savings_provider_certifications', {
      p_organization: organizationId, p_actor: actorId,
    });
    if (!Array.isArray(data)) throw new Error('Savings provider certification list is invalid.');
    return data;
  }

  async readReadiness(query: SavingsProviderReadinessQuery): Promise<SavingsProviderReadiness> {
    const data = await this.rpc('read_savings_provider_readiness', {
      p_organization: query.organizationId, p_actor: query.actorId,
      p_provider_code: query.providerCode, p_environment: query.environment,
      p_jurisdiction: query.jurisdiction, p_currency: query.currency,
      p_configuration_fingerprint: query.configurationFingerprint,
    });
    return data as SavingsProviderReadiness;
  }
}

export class SavingsProviderCertificationService {
  constructor(
    private readonly gateway: SavingsProviderCertificationGateway = new SupabaseSavingsProviderCertificationGateway(),
    private readonly now = () => new Date(),
  ) {}

  create(command: CreateSavingsProviderCertificationCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.operationalOwnerId, 'Operational owner');
    if (!PROVIDER_CODE_PATTERN.test(command.providerCode)) {
      throw new SavingsProviderCertificationError('Provider code is invalid.');
    }
    if (command.providerLegalName.trim().length < 2 || command.providerLegalName.trim().length > 160) {
      throw new SavingsProviderCertificationError('Provider legal name is invalid.');
    }
    if (!JURISDICTION_PATTERN.test(command.jurisdiction) || !CURRENCY_PATTERN.test(command.currency)) {
      throw new SavingsProviderCertificationError('Jurisdiction or currency is invalid.');
    }
    if (!Number.isSafeInteger(command.version) || command.version < 1 || command.version > 2147483647) {
      throw new SavingsProviderCertificationError('Certification version must be a positive integer.');
    }
    if (!HASH_PATTERN.test(command.configurationFingerprint)) {
      throw new SavingsProviderCertificationError('Configuration fingerprint must be a lowercase SHA-256 hash.');
    }
    const references: Array<[string, string]> = [
      [command.providerContractReference, 'Provider contract reference'],
      [command.credentialsValidationReference, 'Credentials validation reference'],
      [command.webhookCertificationReference, 'Webhook certification reference'],
      [command.settlementAccountReference, 'Settlement account reference'],
      [command.complianceNotesReference, 'Compliance notes reference'],
      [command.threatModelReference, 'Threat model reference'],
      [command.dataProtectionReviewReference, 'Data-protection review reference'],
      [command.supportRunbookReference, 'Support runbook reference'],
      [command.reconciliationSignoffReference, 'Reconciliation sign-off reference'],
      [command.limitsDisclosuresReference, 'Limits and disclosures reference'],
    ];
    references.forEach(([value, label]) => assertReference(value, label));
    if (canonicalTime(command.validUntil, 'Validity deadline') <= this.now()) {
      throw new SavingsProviderCertificationError('Validity deadline must be in the future.');
    }
    return this.gateway.create(command);
  }

  recordScenario(command: RecordSavingsCertificationScenarioCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.certificationId, 'Certification');
    if (!SAVINGS_CERTIFICATION_SCENARIOS.includes(command.scenarioCode)) {
      throw new SavingsProviderCertificationError('Certification scenario is invalid.');
    }
    if (!Number.isSafeInteger(command.attemptNumber) || command.attemptNumber < 1
      || command.attemptNumber > 2147483647) {
      throw new SavingsProviderCertificationError('Scenario attempt must be a positive integer.');
    }
    if (!Number.isSafeInteger(command.unexplainedVarianceMinor) || command.unexplainedVarianceMinor < 0) {
      throw new SavingsProviderCertificationError('Unexplained variance must be a non-negative safe integer.');
    }
    if (command.scenarioCode !== 'reconciliation_zero_variance' && command.unexplainedVarianceMinor !== 0) {
      throw new SavingsProviderCertificationError('Only reconciliation evidence may carry unexplained variance.');
    }
    assertReference(command.evidenceReference, 'Scenario evidence reference');
    if (!HASH_PATTERN.test(command.evidenceSha256)) {
      throw new SavingsProviderCertificationError('Scenario evidence hash must be a lowercase SHA-256 hash.');
    }
    const startedAt = canonicalTime(command.startedAt, 'Scenario start');
    const completedAt = canonicalTime(command.completedAt, 'Scenario completion');
    if (completedAt < startedAt || completedAt > this.now()) {
      throw new SavingsProviderCertificationError('Scenario timing is invalid.');
    }
    return this.gateway.recordScenario(command);
  }

  submit(command: SavingsCertificationTransitionCommand) {
    this.validateTransition(command);
    return this.gateway.submit(command);
  }

  decide(command: DecideSavingsCertificationCommand) {
    this.validateTransition(command);
    return this.gateway.decide(command);
  }

  list(organizationId: string, actorId: string) {
    assertUuid(organizationId, 'Organization');
    assertUuid(actorId, 'Actor');
    return this.gateway.list(organizationId, actorId);
  }

  readiness(query: SavingsProviderReadinessQuery) {
    assertUuid(query.organizationId, 'Organization');
    assertUuid(query.actorId, 'Actor');
    if (!PROVIDER_CODE_PATTERN.test(query.providerCode) || !HASH_PATTERN.test(query.configurationFingerprint)
      || !JURISDICTION_PATTERN.test(query.jurisdiction) || !CURRENCY_PATTERN.test(query.currency)) {
      throw new SavingsProviderCertificationError('Savings provider readiness query is invalid.');
    }
    return this.gateway.readReadiness(query);
  }

  private validateIdentity(organizationId: string, actorId: string, idempotencyKey: string) {
    assertUuid(organizationId, 'Organization');
    assertUuid(actorId, 'Actor');
    assertIdempotencyKey(idempotencyKey);
  }

  private validateTransition(command: SavingsCertificationTransitionCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.certificationId, 'Certification');
    assertReference(command.reason, 'Decision reason');
  }
}

export interface SavingsProviderEnvironmentSource {
  NODE_ENV?: string;
  SAVINGS_PROVIDER_MODE?: string;
  SAVINGS_PROVIDER_CODE?: string;
  SAVINGS_PROVIDER_ADAPTER_CODE?: string;
  SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT?: string;
  SAVINGS_PROVIDER_JURISDICTION?: string;
  SAVINGS_PROVIDER_CURRENCY?: string;
}

export class SavingsProviderActivationGuard {
  constructor(
    private readonly certification: Pick<SavingsProviderCertificationService, 'readiness'> = new SavingsProviderCertificationService(),
    private readonly environment = (): SavingsProviderEnvironmentSource => process.env as SavingsProviderEnvironmentSource,
  ) {}

  async assertNewExposureReady(organizationId: string, actorId: string): Promise<void> {
    const env = this.environment();
    const mode = (env.SAVINGS_PROVIDER_MODE
      ?? (env.NODE_ENV === 'production' ? 'live' : 'deterministic')) as SavingsProviderEnvironment;
    if (!['deterministic', 'sandbox', 'live'].includes(mode)) {
      throw new SavingsProviderConfigurationError('Savings provider mode is invalid.', 'SAVINGS_PROVIDER_MODE_INVALID');
    }
    if (mode === 'deterministic') {
      if (env.NODE_ENV === 'production') {
        throw new SavingsProviderConfigurationError(
          'Deterministic savings custody cannot run in production.',
          'DETERMINISTIC_SAVINGS_PROVIDER_FORBIDDEN',
        );
      }
      return;
    }
    const providerCode = env.SAVINGS_PROVIDER_CODE ?? '';
    const adapterCode = env.SAVINGS_PROVIDER_ADAPTER_CODE ?? '';
    const configurationFingerprint = env.SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT ?? '';
    const jurisdiction = env.SAVINGS_PROVIDER_JURISDICTION ?? 'NG';
    const currency = env.SAVINGS_PROVIDER_CURRENCY ?? 'NGN';
    const missingConfiguration = [
      !PROVIDER_CODE_PATTERN.test(providerCode) ? 'provider_code' : undefined,
      adapterCode !== providerCode ? 'provider_adapter' : undefined,
      !HASH_PATTERN.test(configurationFingerprint) ? 'configuration_fingerprint' : undefined,
      !JURISDICTION_PATTERN.test(jurisdiction) ? 'jurisdiction' : undefined,
      !CURRENCY_PATTERN.test(currency) ? 'currency' : undefined,
    ].filter((value): value is string => Boolean(value));
    if (missingConfiguration.length) {
      throw new SavingsProviderConfigurationError(
        'Savings provider configuration is incomplete.',
        'SAVINGS_PROVIDER_CONFIGURATION_INCOMPLETE',
        missingConfiguration,
      );
    }
    const readiness = await this.certification.readiness({
      organizationId, actorId, providerCode, environment: mode,
      jurisdiction, currency, configurationFingerprint,
    });
    if (!readiness.ready) {
      throw new SavingsProviderConfigurationError(
        'Savings provider certification or activation is incomplete.',
        'SAVINGS_PROVIDER_NOT_READY',
        readiness.missing,
      );
    }
  }
}

export const savingsProviderCertificationService = new SavingsProviderCertificationService();
export const savingsProviderActivationGuard = new SavingsProviderActivationGuard();
