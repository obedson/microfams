import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface AssessLoanDelinquencyCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  contractId: string;
  assessedOn: string;
  correlationId: string;
  idempotencyKey: string;
}

export interface LoanDelinquencyGateway {
  assess(command: AssessLoanDelinquencyCommand): Promise<unknown>;
}

export class LoanDelinquencyValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanDelinquencyValidationError';
  }
}

export class SupabaseLoanDelinquencyGateway implements LoanDelinquencyGateway {
  async assess(command: AssessLoanDelinquencyCommand) {
    const { data, error } = await supabase.rpc('assess_loan_delinquency', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_contract: command.contractId,
      p_assessed_on: command.assessedOn,
      p_correlation: command.correlationId,
      p_idempotency_key: command.idempotencyKey,
    });
    if (error || data === null) throw error ?? new Error('Loan delinquency storage returned no result.');
    return data;
  }
}

export class LoanDelinquencyService {
  constructor(private readonly gateway: LoanDelinquencyGateway = new SupabaseLoanDelinquencyGateway()) {}

  assess(command: AssessLoanDelinquencyCommand) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    this.uuid(command.contractId, 'Contract ID');
    this.uuid(command.correlationId, 'Correlation ID');
    const parsed = new Date(`${command.assessedOn}T00:00:00.000Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(command.assessedOn) || Number.isNaN(parsed.getTime())
      || parsed.toISOString().slice(0, 10) !== command.assessedOn) {
      throw new LoanDelinquencyValidationError('Assessment date must be a valid YYYY-MM-DD date.');
    }
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new LoanDelinquencyValidationError('Idempotency key must contain 8 to 160 characters.');
    }
    return this.gateway.assess(command);
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanDelinquencyValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanDelinquencyService = new LoanDelinquencyService();
