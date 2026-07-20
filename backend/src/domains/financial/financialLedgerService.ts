import { createHash } from 'node:crypto';
import { FeatureFlagEnvironment } from '../../types/featureFlags.js';
import {
  FinancialFeatureGate,
  FinancialJournalGateway,
  JournalLineInput,
  JournalPostingRecord,
  PostJournalCommand,
} from './types.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;
const SOURCE_PATTERN = /^[a-z][a-z0-9_.-]{1,63}$/;
const MAX_INT64 = 9223372036854775807n;

export class FinancialValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FinancialValidationError';
  }
}

export class FinancialFeatureDisabledError extends Error {
  constructor(reason: string) {
    super(`Financial accounting posting is disabled: ${reason}`);
    this.name = 'FinancialFeatureDisabledError';
  }
}

const currentEnvironment = (): FeatureFlagEnvironment => {
  const environment = process.env.NODE_ENV;
  if (environment === 'production' || environment === 'staging' || environment === 'test') return environment;
  return 'development';
};

const validateLine = (line: JournalLineInput) => {
  if (!UUID_PATTERN.test(line.accountId)) throw new FinancialValidationError('Every journal line requires a valid account ID.');
  if (!Number.isSafeInteger(line.lineNumber) || line.lineNumber <= 0) {
    throw new FinancialValidationError('Journal line numbers must be positive safe integers.');
  }
  if (line.side !== 'debit' && line.side !== 'credit') throw new FinancialValidationError('Journal side must be debit or credit.');
  if (typeof line.amountMinor !== 'bigint' || line.amountMinor <= 0n || line.amountMinor > MAX_INT64) {
    throw new FinancialValidationError('Journal amounts must be positive signed 64-bit minor units.');
  }
  if (line.memo && line.memo.length > 300) throw new FinancialValidationError('Journal line memo is too long.');
};

const canonicalize = (command: PostJournalCommand): JournalPostingRecord['lines'] => command.lines
  .map((line) => {
    validateLine(line);
    return {
      accountId: line.accountId.toLowerCase(),
      lineNumber: line.lineNumber,
      side: line.side,
      amountMinor: line.amountMinor.toString(),
      ...(line.memo ? { memo: line.memo } : {}),
    };
  })
  .sort((left, right) => left.lineNumber - right.lineNumber);

export class FinancialLedgerService {
  constructor(
    private readonly gateway: FinancialJournalGateway,
    private readonly featureGate: FinancialFeatureGate,
    private readonly environment: FeatureFlagEnvironment = currentEnvironment(),
  ) {}

  async post(command: PostJournalCommand): Promise<{ journalEntryId: string; requestHash: string }> {
    const decision = await this.featureGate.evaluate('financial.accounting.post', {
      environment: this.environment,
      tenantId: command.organizationId,
      actorId: command.actorId,
      jurisdiction: command.jurisdiction,
    });
    if (!decision.enabled) throw new FinancialFeatureDisabledError(decision.reason);

    this.validateCommand(command);
    const lines = canonicalize(command);
    if (new Set(lines.map((line) => line.lineNumber)).size !== lines.length) {
      throw new FinancialValidationError('Journal line numbers must be unique.');
    }
    const debitTotal = lines.filter((line) => line.side === 'debit')
      .reduce((sum, line) => sum + BigInt(line.amountMinor), 0n);
    const creditTotal = lines.filter((line) => line.side === 'credit')
      .reduce((sum, line) => sum + BigInt(line.amountMinor), 0n);
    if (debitTotal <= 0n || debitTotal !== creditTotal) {
      throw new FinancialValidationError('Journal debits and credits must be positive and balanced.');
    }

    const hashPayload = {
      organizationId: command.organizationId.toLowerCase(),
      currency: command.currency,
      effectiveDate: command.effectiveDate,
      sourceDomain: command.sourceDomain,
      sourceRecordId: command.sourceRecordId,
      idempotencyKey: command.idempotencyKey,
      correlationId: command.correlationId.toLowerCase(),
      description: command.description,
      actorId: command.actorId?.toLowerCase() || null,
      lines,
    };
    const requestHash = createHash('sha256').update(JSON.stringify(hashPayload)).digest('hex');
    const journalEntryId = await this.gateway.post({
      ...command,
      organizationId: command.organizationId.toLowerCase(),
      currency: command.currency,
      correlationId: command.correlationId.toLowerCase(),
      actorId: command.actorId?.toLowerCase(),
      requestHash,
      lines,
    });
    return { journalEntryId, requestHash };
  }

  private validateCommand(command: PostJournalCommand) {
    if (!UUID_PATTERN.test(command.organizationId)) throw new FinancialValidationError('A valid organization ID is required.');
    if (command.actorId && !UUID_PATTERN.test(command.actorId)) throw new FinancialValidationError('Actor ID must be a valid UUID.');
    if (!UUID_PATTERN.test(command.correlationId)) throw new FinancialValidationError('Correlation ID must be a valid UUID.');
    if (!CURRENCY_PATTERN.test(command.currency)) throw new FinancialValidationError('Currency must be an uppercase ISO code.');
    const effectiveDate = new Date(`${command.effectiveDate}T00:00:00.000Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(command.effectiveDate) || Number.isNaN(effectiveDate.getTime())
      || effectiveDate.toISOString().slice(0, 10) !== command.effectiveDate) {
      throw new FinancialValidationError('Effective date must be a valid YYYY-MM-DD date.');
    }
    if (!SOURCE_PATTERN.test(command.sourceDomain)) throw new FinancialValidationError('Source domain is invalid.');
    if (!command.sourceRecordId || command.sourceRecordId.length > 160) throw new FinancialValidationError('Source record ID is required.');
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new FinancialValidationError('Idempotency key must contain 8 to 160 characters.');
    }
    if (command.description.trim().length < 2 || command.description.length > 500) {
      throw new FinancialValidationError('Journal description must contain 2 to 500 characters.');
    }
    if (command.lines.length < 2) throw new FinancialValidationError('A journal requires at least two lines.');
  }
}
