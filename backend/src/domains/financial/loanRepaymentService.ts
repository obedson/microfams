import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface RecordLoanRepaymentCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  contractId: string;
  amountMinor: number;
  effectiveDate: string;
  correlationId: string;
  idempotencyKey: string;
}

export interface LoanRepaymentGateway {
  record(command: RecordLoanRepaymentCommand): Promise<unknown>;
}

export class LoanRepaymentValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanRepaymentValidationError';
  }
}

export class SupabaseLoanRepaymentGateway implements LoanRepaymentGateway {
  async record(command: RecordLoanRepaymentCommand) {
    const { data, error } = await supabase.rpc('record_loan_repayment', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_contract: command.contractId,
      p_amount_minor: command.amountMinor,
      p_effective_date: command.effectiveDate,
      p_correlation: command.correlationId,
      p_idempotency_key: command.idempotencyKey,
    });
    if (error || data === null) throw error ?? new Error('Loan repayment storage returned no result.');
    return data;
  }
}

export class LoanRepaymentService {
  constructor(private readonly gateway: LoanRepaymentGateway = new SupabaseLoanRepaymentGateway()) {}

  record(command: RecordLoanRepaymentCommand) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    this.uuid(command.contractId, 'Contract ID');
    this.uuid(command.correlationId, 'Correlation ID');
    if (!Number.isSafeInteger(command.amountMinor) || command.amountMinor <= 0) {
      throw new LoanRepaymentValidationError('Repayment amount must be a positive safe integer in minor units.');
    }
    const parsed = new Date(`${command.effectiveDate}T00:00:00.000Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(command.effectiveDate) || Number.isNaN(parsed.getTime())
      || parsed.toISOString().slice(0, 10) !== command.effectiveDate) {
      throw new LoanRepaymentValidationError('Effective date must be a valid YYYY-MM-DD date.');
    }
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new LoanRepaymentValidationError('Idempotency key must contain 8 to 160 characters.');
    }
    return this.gateway.record(command);
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanRepaymentValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanRepaymentService = new LoanRepaymentService();
