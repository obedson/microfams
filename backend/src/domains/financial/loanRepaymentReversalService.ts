import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface ProposeLoanRepaymentReversalCommand {
  organizationId: string; actorId: string; applicationId: string; contractId: string; repaymentId: string;
  reasonCode: string; reason: string; evidenceReferences: unknown[]; correlationId: string; idempotencyKey: string;
}
export interface DecideLoanRepaymentReversalCommand {
  organizationId: string; actorId: string; reversalId: string; decision: 'approve'|'reject'; reviewReason: string;
  correlationId: string; idempotencyKey: string;
}
export interface LoanRepaymentReversalGateway {
  propose(command: ProposeLoanRepaymentReversalCommand): Promise<unknown>;
  decide(command: DecideLoanRepaymentReversalCommand): Promise<unknown>;
}
export class LoanRepaymentReversalValidationError extends Error {
  constructor(message: string) { super(message); this.name = 'LoanRepaymentReversalValidationError'; }
}
export class SupabaseLoanRepaymentReversalGateway implements LoanRepaymentReversalGateway {
  async propose(command: ProposeLoanRepaymentReversalCommand) {
    const {data,error}=await supabase.rpc('propose_loan_repayment_reversal',{p_organization:command.organizationId,p_actor:command.actorId,p_application:command.applicationId,p_contract:command.contractId,p_repayment:command.repaymentId,p_reason_code:command.reasonCode,p_reason:command.reason,p_evidence:command.evidenceReferences,p_correlation:command.correlationId,p_idempotency_key:command.idempotencyKey});
    if(error||data===null) throw error??new Error('Loan repayment reversal storage returned no result.'); return data;
  }
  async decide(command: DecideLoanRepaymentReversalCommand) {
    const {data,error}=await supabase.rpc('decide_loan_repayment_reversal',{p_organization:command.organizationId,p_actor:command.actorId,p_reversal:command.reversalId,p_decision:command.decision,p_review_reason:command.reviewReason,p_correlation:command.correlationId,p_idempotency_key:command.idempotencyKey});
    if(error||data===null) throw error??new Error('Loan repayment reversal decision storage returned no result.'); return data;
  }
}
export class LoanRepaymentReversalService {
  constructor(private readonly gateway: LoanRepaymentReversalGateway = new SupabaseLoanRepaymentReversalGateway()) {}
  propose(command: ProposeLoanRepaymentReversalCommand) {
    this.ids([['Organization ID',command.organizationId],['Actor ID',command.actorId],['Application ID',command.applicationId],['Contract ID',command.contractId],['Repayment ID',command.repaymentId],['Correlation ID',command.correlationId]]);
    if(!/^[A-Z][A-Z0-9_]{2,39}$/.test(command.reasonCode)) throw new LoanRepaymentReversalValidationError('Reason code is invalid.');
    if(command.reason.trim().length<12||command.reason.trim().length>500) throw new LoanRepaymentReversalValidationError('Reason must contain 12 to 500 characters.');
    if(!Array.isArray(command.evidenceReferences)||command.evidenceReferences.length===0) throw new LoanRepaymentReversalValidationError('Evidence references are required.');
    this.key(command.idempotencyKey); return this.gateway.propose(command);
  }
  decide(command: DecideLoanRepaymentReversalCommand) {
    this.ids([['Organization ID',command.organizationId],['Actor ID',command.actorId],['Reversal ID',command.reversalId],['Correlation ID',command.correlationId]]);
    if(!['approve','reject'].includes(command.decision)) throw new LoanRepaymentReversalValidationError('Decision is invalid.');
    if(command.reviewReason.trim().length<12||command.reviewReason.trim().length>500) throw new LoanRepaymentReversalValidationError('Review reason must contain 12 to 500 characters.');
    this.key(command.idempotencyKey); return this.gateway.decide(command);
  }
  private ids(values:Array<[string,string]>) { for(const [label,value] of values) if(!UUID_PATTERN.test(value)) throw new LoanRepaymentReversalValidationError(`${label} must be a valid UUID.`); }
  private key(value:string) { if(value.length<8||value.length>160) throw new LoanRepaymentReversalValidationError('Idempotency key must contain 8 to 160 characters.'); }
}
export const loanRepaymentReversalService = new LoanRepaymentReversalService();
