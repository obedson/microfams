import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const RULE_CODE_PATTERN = /^[a-z][a-z0-9_]{1,39}$/;
const REASON_CODE_PATTERN = /^[A-Z][A-Z0-9_]{2,79}$/;
const REFERENCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$/;

export type LoanBorrowerType = 'individual' | 'group' | 'organization';
export type AdverseReviewDecision = 'uphold' | 'reopen';

export interface CreateLoanApplicationCommand {
  organizationId: string;
  actorId: string;
  productId: string;
  borrowerType: LoanBorrowerType;
  borrowerId?: string;
  purpose: string;
  requestedPrincipalMinor: number;
  requestedTenorDays: number;
  monthlyNetIncomeMinor: number;
  monthlyExistingDebtMinor: number;
  verifiedIncomeMonths: number;
  incomeEvidenceReferences: string[];
  identityEvidenceId?: string;
  disclosureVersion: string;
  disclosureContentHash: string;
  declarationVersion: string;
  declarationContentHash: string;
  idempotencyKey: string;
}

export interface LoanApplicationCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  idempotencyKey: string;
}

export interface RequestLoanAdverseReviewCommand extends LoanApplicationCommand {
  reason: string;
  evidenceReferences: string[];
}

export interface DecideLoanAdverseReviewCommand extends LoanApplicationCommand {
  decision: AdverseReviewDecision;
  reason: string;
}

export interface WithdrawLoanApplicationCommand extends LoanApplicationCommand {
  reasonCode: string;
}

export interface LoanApplicationGateway {
  createApplication(command: CreateLoanApplicationCommand): Promise<unknown>;
  submitApplication(command: LoanApplicationCommand): Promise<unknown>;
  requestAdverseReview(command: RequestLoanAdverseReviewCommand): Promise<unknown>;
  decideAdverseReview(command: DecideLoanAdverseReviewCommand): Promise<unknown>;
  withdrawApplication(command: WithdrawLoanApplicationCommand): Promise<unknown>;
  listApplications(organizationId: string, actorId: string): Promise<unknown[]>;
}

export class LoanApplicationValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanApplicationValidationError';
  }
}

export class SupabaseLoanApplicationGateway implements LoanApplicationGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Loan application storage returned no result.');
    return data;
  }

  createApplication(command: CreateLoanApplicationCommand) {
    return this.rpc('create_loan_application_draft', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_product: command.productId,
      p_borrower_type: command.borrowerType,
      p_borrower: command.borrowerId ?? null,
      p_purpose: command.purpose,
      p_principal_minor: command.requestedPrincipalMinor,
      p_tenor_days: command.requestedTenorDays,
      p_monthly_income_minor: command.monthlyNetIncomeMinor,
      p_monthly_debt_minor: command.monthlyExistingDebtMinor,
      p_verified_income_months: command.verifiedIncomeMonths,
      p_income_evidence: command.incomeEvidenceReferences,
      p_identity_evidence: command.identityEvidenceId ?? null,
      p_disclosure_version: command.disclosureVersion,
      p_disclosure_hash: command.disclosureContentHash,
      p_declaration_version: command.declarationVersion,
      p_declaration_hash: command.declarationContentHash,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  submitApplication(command: LoanApplicationCommand) {
    return this.rpc('submit_loan_application', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  requestAdverseReview(command: RequestLoanAdverseReviewCommand) {
    return this.rpc('request_loan_adverse_review', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_reason: command.reason,
      p_evidence: command.evidenceReferences,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  decideAdverseReview(command: DecideLoanAdverseReviewCommand) {
    return this.rpc('decide_loan_adverse_review', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_decision: command.decision,
      p_reason: command.reason,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  withdrawApplication(command: WithdrawLoanApplicationCommand) {
    return this.rpc('withdraw_loan_application', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_reason_code: command.reasonCode,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  async listApplications(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_loan_applications', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Loan application list is invalid.');
    return data;
  }
}

export class LoanApplicationService {
  constructor(private readonly gateway: LoanApplicationGateway = new SupabaseLoanApplicationGateway()) {}

  createApplication(command: CreateLoanApplicationCommand) {
    this.identity(command.organizationId, command.actorId, command.idempotencyKey);
    this.uuid(command.productId, 'Product ID');
    if (!['individual', 'group', 'organization'].includes(command.borrowerType)) {
      throw new LoanApplicationValidationError('Borrower type is invalid.');
    }
    if (command.borrowerType === 'individual' && command.borrowerId && command.borrowerId !== command.actorId) {
      throw new LoanApplicationValidationError('Individuals may apply only for themselves.');
    }
    if (command.borrowerType !== 'individual' && !command.borrowerId) {
      throw new LoanApplicationValidationError('Group and organization applications require a borrower ID.');
    }
    if (command.borrowerId) this.uuid(command.borrowerId, 'Borrower ID');
    if (!RULE_CODE_PATTERN.test(command.purpose)) throw new LoanApplicationValidationError('Purpose is invalid.');
    this.positiveMinor(command.requestedPrincipalMinor, 'Requested principal');
    this.positiveInteger(command.requestedTenorDays, 'Requested tenor');
    this.positiveMinor(command.monthlyNetIncomeMinor, 'Monthly net income');
    this.nonNegativeInteger(command.monthlyExistingDebtMinor, 'Monthly existing debt');
    this.nonNegativeInteger(command.verifiedIncomeMonths, 'Verified income months');
    this.references(command.incomeEvidenceReferences, 'Income evidence');
    if (command.identityEvidenceId) this.uuid(command.identityEvidenceId, 'Identity evidence ID');
    this.versionHash(command.disclosureVersion, command.disclosureContentHash, 'Disclosure');
    this.versionHash(command.declarationVersion, command.declarationContentHash, 'Declaration');
    return this.gateway.createApplication(command);
  }

  submitApplication(command: LoanApplicationCommand) {
    this.applicationCommand(command);
    return this.gateway.submitApplication(command);
  }

  requestAdverseReview(command: RequestLoanAdverseReviewCommand) {
    this.applicationCommand(command);
    this.reason(command.reason, 'Review request');
    this.references(command.evidenceReferences, 'Review evidence');
    return this.gateway.requestAdverseReview(command);
  }

  decideAdverseReview(command: DecideLoanAdverseReviewCommand) {
    this.applicationCommand(command);
    if (!['uphold', 'reopen'].includes(command.decision)) throw new LoanApplicationValidationError('Review decision is invalid.');
    this.reason(command.reason, 'Review decision');
    return this.gateway.decideAdverseReview(command);
  }

  withdrawApplication(command: WithdrawLoanApplicationCommand) {
    this.applicationCommand(command);
    if (!REASON_CODE_PATTERN.test(command.reasonCode)) throw new LoanApplicationValidationError('Withdrawal reason code is invalid.');
    return this.gateway.withdrawApplication(command);
  }

  listApplications(organizationId: string, actorId: string) {
    this.uuid(organizationId, 'Organization ID');
    this.uuid(actorId, 'Actor ID');
    return this.gateway.listApplications(organizationId, actorId);
  }

  private applicationCommand(command: LoanApplicationCommand) {
    this.identity(command.organizationId, command.actorId, command.idempotencyKey);
    this.uuid(command.applicationId, 'Application ID');
  }

  private identity(organizationId: string, actorId: string, idempotencyKey: string) {
    this.uuid(organizationId, 'Organization ID');
    this.uuid(actorId, 'Actor ID');
    if (idempotencyKey.length < 8 || idempotencyKey.length > 160) {
      throw new LoanApplicationValidationError('Idempotency key must contain 8 to 160 characters.');
    }
  }

  private references(references: string[], label: string) {
    if (!Array.isArray(references) || references.length > 20 || references.some((reference) => !REFERENCE_PATTERN.test(reference))) {
      throw new LoanApplicationValidationError(`${label} references are invalid.`);
    }
    if (new Set(references).size !== references.length) throw new LoanApplicationValidationError(`${label} references must be unique.`);
  }

  private reason(value: string, label: string) {
    const length = value.trim().length;
    if (length < 12 || length > 1000) throw new LoanApplicationValidationError(`${label} reason must contain 12 to 1000 characters.`);
  }

  private versionHash(version: string, hash: string, label: string) {
    if (!version.trim() || version.trim().length > 80 || !HASH_PATTERN.test(hash)) {
      throw new LoanApplicationValidationError(`${label} version and SHA-256 hash are required.`);
    }
  }

  private positiveMinor(value: number, label: string) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new LoanApplicationValidationError(`${label} must be a positive safe integer in minor units.`);
  }

  private positiveInteger(value: number, label: string) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new LoanApplicationValidationError(`${label} must be a positive safe integer.`);
  }

  private nonNegativeInteger(value: number, label: string) {
    if (!Number.isSafeInteger(value) || value < 0) throw new LoanApplicationValidationError(`${label} must be a non-negative safe integer.`);
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanApplicationValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanApplicationService = new LoanApplicationService();
