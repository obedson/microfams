import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from 'crypto';
import { supabase } from '../../utils/supabase.js';
import { configuredPayoutAdapter } from './payoutAdapters.js';
import { PayoutAdapter, PayoutDestination } from './payoutTypes.js';
import { PayoutService, payoutService } from './payoutService.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONDITION_CODE_PATTERN = /^[A-Z][A-Z0-9_]{2,79}$/;
const REFERENCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$/;
const PROVIDER_PATTERN = /^[a-z][a-z0-9_-]{1,31}$/;

const sha256 = (value: string | Buffer) => createHash('sha256').update(value).digest('hex');
const maskedAccount = (accountNumber: string) => `******${accountNumber.slice(-4)}`;
const maskedName = (name: string) => {
  const normalized = name.trim();
  if (normalized.length <= 4) return normalized[0] + '*'.repeat(Math.max(1, normalized.length - 1));
  return `${normalized.slice(0, 2)}${'*'.repeat(Math.min(12, normalized.length - 4))}${normalized.slice(-2)}`;
};

const encryptionKey = (
  configured = process.env.LOAN_DISBURSEMENT_DESTINATION_ENCRYPTION_KEY,
) => {
  if (!configured) {
    throw new LoanDisbursementValidationError(
      'Loan disbursement destination encryption is not configured.',
    );
  }
  const key = /^[a-f0-9]{64}$/i.test(configured)
    ? Buffer.from(configured, 'hex')
    : Buffer.from(configured, 'base64');
  if (key.length !== 32) {
    throw new LoanDisbursementValidationError(
      'Loan disbursement destination encryption key must contain 32 bytes.',
    );
  }
  return key;
};

export const encryptLoanDisbursementDestination = (
  destination: PayoutDestination,
  configuredKey?: string,
) => {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', encryptionKey(configuredKey), iv);
  const encrypted = Buffer.concat([
    cipher.update(JSON.stringify(destination), 'utf8'),
    cipher.final(),
  ]);
  return ['v1', iv.toString('base64url'), cipher.getAuthTag().toString('base64url'),
    encrypted.toString('base64url')].join('.');
};

export const decryptLoanDisbursementDestination = (
  ciphertext: string,
  configuredKey?: string,
): PayoutDestination => {
  const [version, iv, tag, encrypted] = ciphertext.split('.');
  if (version !== 'v1' || !iv || !tag || !encrypted) {
    throw new LoanDisbursementValidationError('Encrypted loan destination is invalid.');
  }
  try {
    const decipher = createDecipheriv(
      'aes-256-gcm', encryptionKey(configuredKey), Buffer.from(iv, 'base64url'),
    );
    decipher.setAuthTag(Buffer.from(tag, 'base64url'));
    return JSON.parse(Buffer.concat([
      decipher.update(Buffer.from(encrypted, 'base64url')),
      decipher.final(),
    ]).toString('utf8'));
  } catch (error) {
    if (error instanceof LoanDisbursementValidationError) throw error;
    throw new LoanDisbursementValidationError('Encrypted loan destination could not be opened.');
  }
};

export interface LoanCommandIdentity {
  organizationId: string;
  actorId: string;
  applicationId: string;
  idempotencyKey: string;
}

export interface InitializeConditionsCommand extends LoanCommandIdentity {
  offerId: string;
  scheduleId: string;
}

export interface SubmitConditionEvidenceCommand extends LoanCommandIdentity {
  conditionId: string;
  evidenceReferences: string[];
}

export interface DecideConditionCommand extends LoanCommandIdentity {
  conditionId: string;
  decision: 'satisfy' | 'reject';
  reason: string;
}

export interface ProposeDestinationCommand extends LoanCommandIdentity {
  accountNumber: string;
  bankCode: string;
}

export interface DecideDestinationCommand extends LoanCommandIdentity {
  destinationId: string;
  decision: 'verify' | 'reject';
  reason: string;
}

export interface BeginDisbursementCommand extends LoanCommandIdentity {
  destinationId: string;
  correlationId: string;
}

export interface SyncDisbursementCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  disbursementId: string;
}

export interface LoanDisbursementGateway {
  initializeConditions(command: InitializeConditionsCommand): Promise<unknown>;
  submitConditionEvidence(command: SubmitConditionEvidenceCommand): Promise<unknown>;
  decideCondition(command: DecideConditionCommand): Promise<unknown>;
  proposeDestination(command: ProposeDestinationCommand & {
    providerName: string;
    providerEnvironment: string;
    destinationCiphertext: string;
    destinationFingerprint: string;
    destinationMasked: string;
    accountNameMasked: string;
    verificationSnapshot: Record<string, unknown>;
  }): Promise<unknown>;
  decideDestination(command: DecideDestinationCommand): Promise<unknown>;
  beginDisbursement(command: BeginDisbursementCommand & {
    providerName: string;
    providerEnvironment: string;
  }): Promise<any>;
  getDisbursement(command: SyncDisbursementCommand): Promise<any>;
}

export class SupabaseLoanDisbursementGateway implements LoanDisbursementGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Loan disbursement storage returned no result.');
    return data;
  }

  initializeConditions(command: InitializeConditionsCommand) {
    return this.rpc('initialize_loan_conditions', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_offer: command.offerId,
      p_schedule: command.scheduleId, p_idempotency_key: command.idempotencyKey,
    });
  }

  submitConditionEvidence(command: SubmitConditionEvidenceCommand) {
    return this.rpc('submit_loan_condition_evidence', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_condition: command.conditionId,
      p_evidence: command.evidenceReferences, p_idempotency_key: command.idempotencyKey,
    });
  }

  decideCondition(command: DecideConditionCommand) {
    return this.rpc('decide_loan_condition', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_condition: command.conditionId,
      p_decision: command.decision, p_reason: command.reason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  proposeDestination(command: ProposeDestinationCommand & {
    providerName: string; providerEnvironment: string; destinationCiphertext: string;
    destinationFingerprint: string; destinationMasked: string; accountNameMasked: string;
    verificationSnapshot: Record<string, unknown>;
  }) {
    return this.rpc('propose_loan_disbursement_destination', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_provider_name: command.providerName,
      p_provider_environment: command.providerEnvironment,
      p_ciphertext: command.destinationCiphertext,
      p_fingerprint: command.destinationFingerprint, p_masked: command.destinationMasked,
      p_account_name_masked: command.accountNameMasked,
      p_verification_snapshot: command.verificationSnapshot,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  decideDestination(command: DecideDestinationCommand) {
    return this.rpc('decide_loan_disbursement_destination', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_destination: command.destinationId,
      p_decision: command.decision, p_reason: command.reason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  beginDisbursement(command: BeginDisbursementCommand & {
    providerName: string; providerEnvironment: string;
  }) {
    return this.rpc('begin_loan_disbursement', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_application: command.applicationId, p_destination: command.destinationId,
      p_provider_name: command.providerName,
      p_provider_environment: command.providerEnvironment,
      p_idempotency_key: command.idempotencyKey, p_correlation_id: command.correlationId,
    });
  }

  async getDisbursement(command: SyncDisbursementCommand) {
    const { data, error } = await supabase.from('loan_disbursements').select('*')
      .eq('id', command.disbursementId).eq('organization_id', command.organizationId)
      .eq('application_id', command.applicationId).single();
    if (error || !data) throw error ?? new Error('Loan disbursement was not found.');
    return data;
  }
}

export class LoanDisbursementValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanDisbursementValidationError';
  }
}

export class LoanDisbursementService {
  constructor(
    private readonly gateway: LoanDisbursementGateway = new SupabaseLoanDisbursementGateway(),
    private readonly adapterFactory: () => PayoutAdapter = configuredPayoutAdapter,
    private readonly payouts: Pick<PayoutService,
      'assertRoutingEnabled' | 'submitLoanDisbursementPayout' | 'queryAndApply'> = payoutService,
    private readonly configuredEncryptionKey?: string,
  ) {}

  initializeConditions(command: InitializeConditionsCommand) {
    this.identity(command);
    this.uuid(command.offerId, 'Offer ID');
    this.uuid(command.scheduleId, 'Schedule ID');
    return this.gateway.initializeConditions(command);
  }

  submitConditionEvidence(command: SubmitConditionEvidenceCommand) {
    this.identity(command);
    this.uuid(command.conditionId, 'Condition ID');
    this.references(command.evidenceReferences);
    return this.gateway.submitConditionEvidence(command);
  }

  decideCondition(command: DecideConditionCommand) {
    this.identity(command);
    this.uuid(command.conditionId, 'Condition ID');
    if (!['satisfy', 'reject'].includes(command.decision)) {
      throw new LoanDisbursementValidationError('Condition decision is invalid.');
    }
    this.reason(command.reason);
    return this.gateway.decideCondition(command);
  }

  async proposeDestination(command: ProposeDestinationCommand) {
    this.identity(command);
    if (!/^\d{6,20}$/.test(command.accountNumber)) {
      throw new LoanDisbursementValidationError('Destination account number is invalid.');
    }
    if (!/^[A-Za-z0-9._-]{2,40}$/.test(command.bankCode)) {
      throw new LoanDisbursementValidationError('Destination bank code is invalid.');
    }
    const adapter = this.adapterFactory();
    await this.payouts.assertRoutingEnabled(adapter, command.organizationId, command.actorId);
    const verified = await adapter.validateDestination(command.accountNumber, command.bankCode);
    const destination: PayoutDestination = {
      accountNumber: command.accountNumber,
      bankCode: verified.bankCode,
      accountName: verified.accountName,
    };
    const fingerprint = sha256(`${verified.bankCode}:${command.accountNumber}`);
    return this.gateway.proposeDestination({
      ...command,
      providerName: adapter.name,
      providerEnvironment: adapter.environment,
      destinationCiphertext: encryptLoanDisbursementDestination(
        destination, this.configuredEncryptionKey,
      ),
      destinationFingerprint: fingerprint,
      destinationMasked: maskedAccount(command.accountNumber),
      accountNameMasked: maskedName(verified.accountName),
      verificationSnapshot: {
        version: 'CRD-05.DESTINATION.1',
        providerName: adapter.name,
        providerEnvironment: adapter.environment,
        destinationFingerprint: fingerprint,
        accountNameHash: sha256(verified.accountName.trim().toUpperCase()),
        verifiedBankCodeHash: sha256(verified.bankCode),
      },
    });
  }

  decideDestination(command: DecideDestinationCommand) {
    this.identity(command);
    this.uuid(command.destinationId, 'Destination ID');
    if (!['verify', 'reject'].includes(command.decision)) {
      throw new LoanDisbursementValidationError('Destination decision is invalid.');
    }
    this.reason(command.reason);
    return this.gateway.decideDestination(command);
  }

  async beginDisbursement(command: BeginDisbursementCommand) {
    this.identity(command);
    this.uuid(command.destinationId, 'Destination ID');
    this.uuid(command.correlationId, 'Correlation ID');
    const adapter = this.adapterFactory();
    await this.payouts.assertRoutingEnabled(adapter, command.organizationId, command.actorId);
    const result = await this.gateway.beginDisbursement({
      ...command, providerName: adapter.name, providerEnvironment: adapter.environment,
    });
    const ciphertext = result.destination_ciphertext;
    if (typeof ciphertext !== 'string') {
      throw new Error('Loan disbursement destination was not returned by the command engine.');
    }
    const destination = decryptLoanDisbursementDestination(
      ciphertext, this.configuredEncryptionKey,
    );
    const { destination_ciphertext: _removed, ...safeResult } = result;
    const payout = await this.payouts.submitLoanDisbursementPayout({
      payout: result.payout,
      organizationId: command.organizationId,
      actorId: command.actorId,
      destination,
    });
    return { ...safeResult, payout };
  }

  async syncDisbursement(command: SyncDisbursementCommand) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    this.uuid(command.disbursementId, 'Disbursement ID');
    const disbursement = await this.gateway.getDisbursement(command);
    if (!disbursement.payout_id) throw new Error('Loan disbursement payout was not found.');
    return this.payouts.queryAndApply(disbursement.payout_id);
  }

  private identity(command: LoanCommandIdentity) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new LoanDisbursementValidationError('Idempotency key must contain 8 to 160 characters.');
    }
  }

  private references(references: string[]) {
    if (!Array.isArray(references) || references.length < 1 || references.length > 20
      || references.some((reference) => !REFERENCE_PATTERN.test(reference))
      || new Set(references).size !== references.length) {
      throw new LoanDisbursementValidationError('Condition evidence references are invalid.');
    }
  }

  private reason(reason: string) {
    if (reason.trim().length < 12 || reason.trim().length > 1000) {
      throw new LoanDisbursementValidationError('Decision reason must contain 12 to 1000 characters.');
    }
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanDisbursementValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanDisbursementService = new LoanDisbursementService();

export const loanDisbursementPatterns = {
  conditionCode: CONDITION_CODE_PATTERN,
  provider: PROVIDER_PATTERN,
};
