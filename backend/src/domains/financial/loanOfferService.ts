import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const CODE_PATTERN = /^[A-Z][A-Z0-9_]{2,79}$/;

interface BaseLoanOfferCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  idempotencyKey: string;
}

export interface IssueLoanOfferCommand extends BaseLoanOfferCommand {
  principalMinor: number;
  tenorDays: number;
  totalInterestMinor: number;
  totalFeesMinor: number;
  totalRepayableMinor: number;
  conditionCodes: string[];
  disclosureVersion: string;
  disclosureContentHash: string;
  expiresAt: string;
  reasonCodes: string[];
  reviewReason: string;
}

export interface DeclineLoanApplicationCommand extends BaseLoanOfferCommand {
  reasonCodes: string[];
  reviewReason: string;
}

export interface AcceptLoanOfferCommand extends BaseLoanOfferCommand {
  offerId: string;
  expectedOfferHash: string;
  acceptanceVersion: string;
  acceptanceContentHash: string;
}

export interface ExpireLoanOfferCommand extends BaseLoanOfferCommand {
  offerId: string;
  reasonCode: string;
}

export interface LoanOfferGateway {
  issue(command: IssueLoanOfferCommand): Promise<unknown>;
  decline(command: DeclineLoanApplicationCommand): Promise<unknown>;
  accept(command: AcceptLoanOfferCommand): Promise<unknown>;
  expire(command: ExpireLoanOfferCommand): Promise<unknown>;
}

export class LoanOfferValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanOfferValidationError';
  }
}

export class SupabaseLoanOfferGateway implements LoanOfferGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Loan offer storage returned no result.');
    return data;
  }

  issue(command: IssueLoanOfferCommand) {
    return this.rpc('issue_loan_offer', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_principal_minor: command.principalMinor,
      p_tenor_days: command.tenorDays,
      p_total_interest_minor: command.totalInterestMinor,
      p_total_fees_minor: command.totalFeesMinor,
      p_total_repayable_minor: command.totalRepayableMinor,
      p_condition_codes: command.conditionCodes,
      p_disclosure_version: command.disclosureVersion,
      p_disclosure_hash: command.disclosureContentHash,
      p_expires_at: command.expiresAt,
      p_reason_codes: command.reasonCodes,
      p_review_reason: command.reviewReason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  decline(command: DeclineLoanApplicationCommand) {
    return this.rpc('decline_loan_application', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_reason_codes: command.reasonCodes,
      p_review_reason: command.reviewReason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  accept(command: AcceptLoanOfferCommand) {
    return this.rpc('accept_loan_offer', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_offer: command.offerId,
      p_expected_offer_hash: command.expectedOfferHash,
      p_acceptance_version: command.acceptanceVersion,
      p_acceptance_hash: command.acceptanceContentHash,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  expire(command: ExpireLoanOfferCommand) {
    return this.rpc('expire_loan_offer', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_offer: command.offerId,
      p_reason_code: command.reasonCode,
      p_idempotency_key: command.idempotencyKey,
    });
  }
}

export class LoanOfferService {
  constructor(private readonly gateway: LoanOfferGateway = new SupabaseLoanOfferGateway()) {}

  issue(command: IssueLoanOfferCommand) {
    this.base(command);
    this.positiveMinor(command.principalMinor, 'Principal');
    this.positiveMinor(command.tenorDays, 'Tenor');
    this.nonNegativeMinor(command.totalInterestMinor, 'Total interest');
    this.nonNegativeMinor(command.totalFeesMinor, 'Total fees');
    this.positiveMinor(command.totalRepayableMinor, 'Total repayable');
    if (command.totalRepayableMinor !== command.principalMinor + command.totalInterestMinor + command.totalFeesMinor) {
      throw new LoanOfferValidationError('Total repayable must equal principal, interest, and fees.');
    }
    this.codes(command.conditionCodes, 'Condition', true);
    this.codes(command.reasonCodes, 'Decision', false);
    this.reason(command.reviewReason);
    this.versionHash(command.disclosureVersion, command.disclosureContentHash, 'Disclosure');
    const expiry = Date.parse(command.expiresAt);
    if (!Number.isFinite(expiry)) throw new LoanOfferValidationError('Offer expiry must be a valid timestamp.');
    return this.gateway.issue(command);
  }

  decline(command: DeclineLoanApplicationCommand) {
    this.base(command);
    this.codes(command.reasonCodes, 'Decision', false);
    this.reason(command.reviewReason);
    return this.gateway.decline(command);
  }

  accept(command: AcceptLoanOfferCommand) {
    this.base(command);
    this.uuid(command.offerId, 'Offer ID');
    if (!HASH_PATTERN.test(command.expectedOfferHash)) throw new LoanOfferValidationError('Expected offer hash is invalid.');
    this.versionHash(command.acceptanceVersion, command.acceptanceContentHash, 'Acceptance');
    return this.gateway.accept(command);
  }

  expire(command: ExpireLoanOfferCommand) {
    this.base(command);
    this.uuid(command.offerId, 'Offer ID');
    if (!CODE_PATTERN.test(command.reasonCode)) throw new LoanOfferValidationError('Expiry reason code is invalid.');
    return this.gateway.expire(command);
  }

  private base(command: BaseLoanOfferCommand) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new LoanOfferValidationError('Idempotency key must contain 8 to 160 characters.');
    }
  }

  private codes(codes: string[], label: string, emptyAllowed: boolean) {
    const minimum = emptyAllowed ? 0 : 1;
    if (!Array.isArray(codes) || codes.length < minimum || codes.length > 20
      || codes.some((code) => !CODE_PATTERN.test(code)) || new Set(codes).size !== codes.length) {
      throw new LoanOfferValidationError(`${label} codes are invalid.`);
    }
  }

  private reason(value: string) {
    const length = value.trim().length;
    if (length < 12 || length > 1000) {
      throw new LoanOfferValidationError('Review reason must contain 12 to 1000 characters.');
    }
  }

  private versionHash(version: string, hash: string, label: string) {
    if (!version.trim() || version.trim().length > 80 || !HASH_PATTERN.test(hash)) {
      throw new LoanOfferValidationError(`${label} version and SHA-256 hash are required.`);
    }
  }

  private positiveMinor(value: number, label: string) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new LoanOfferValidationError(`${label} must be a positive safe integer.`);
    }
  }

  private nonNegativeMinor(value: number, label: string) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new LoanOfferValidationError(`${label} must be a non-negative safe integer.`);
    }
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanOfferValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanOfferService = new LoanOfferService();
