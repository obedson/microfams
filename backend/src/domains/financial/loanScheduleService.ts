import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface GenerateLoanScheduleCommand {
  organizationId: string;
  actorId: string;
  applicationId: string;
  offerId: string;
  idempotencyKey: string;
}

export interface LoanScheduleGateway {
  generate(command: GenerateLoanScheduleCommand): Promise<unknown>;
}

export class LoanScheduleValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanScheduleValidationError';
  }
}

export class SupabaseLoanScheduleGateway implements LoanScheduleGateway {
  async generate(command: GenerateLoanScheduleCommand) {
    const { data, error } = await supabase.rpc('generate_loan_repayment_schedule', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_application: command.applicationId,
      p_offer: command.offerId,
      p_idempotency_key: command.idempotencyKey,
    });
    if (error || data === null) throw error ?? new Error('Loan schedule storage returned no result.');
    return data;
  }
}

export class LoanScheduleService {
  constructor(private readonly gateway: LoanScheduleGateway = new SupabaseLoanScheduleGateway()) {}

  generate(command: GenerateLoanScheduleCommand) {
    this.uuid(command.organizationId, 'Organization ID');
    this.uuid(command.actorId, 'Actor ID');
    this.uuid(command.applicationId, 'Application ID');
    this.uuid(command.offerId, 'Offer ID');
    if (command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160) {
      throw new LoanScheduleValidationError('Idempotency key must contain 8 to 160 characters.');
    }
    return this.gateway.generate(command);
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanScheduleValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanScheduleService = new LoanScheduleService();
