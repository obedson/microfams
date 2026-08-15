import { supabase } from '../../utils/supabase.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;

export interface ProposeInvestmentRefundReversalCommand {
  organizationId: string; actorId: string; obligationId: string;
  providerName: string; providerEnvironment: 'deterministic' | 'sandbox' | 'live';
  providerReversalReference: string; providerEventHash: string;
  amountMinor: number; currency: string; occurredAt: string;
  reason: string; evidenceReferences: unknown[]; correlationId: string; idempotencyKey: string;
}
export interface DecideInvestmentRefundReversalCommand {
  organizationId: string; actorId: string; reversalId: string;
  decision: 'approve' | 'reject'; reviewReason: string; correlationId: string; idempotencyKey: string;
}
export interface InvestmentRefundReversalGateway {
  propose(command: ProposeInvestmentRefundReversalCommand): Promise<unknown>;
  decide(command: DecideInvestmentRefundReversalCommand): Promise<unknown>;
}
export class SupabaseInvestmentRefundReversalGateway implements InvestmentRefundReversalGateway {
  async propose(command: ProposeInvestmentRefundReversalCommand) {
    const { data, error } = await supabase.rpc('propose_investment_refund_reversal', {
      p_organization: command.organizationId, p_actor: command.actorId, p_obligation: command.obligationId,
      p_provider_name: command.providerName, p_provider_environment: command.providerEnvironment,
      p_provider_reversal_reference: command.providerReversalReference, p_provider_event_hash: command.providerEventHash,
      p_amount_minor: command.amountMinor, p_currency: command.currency, p_occurred_at: command.occurredAt,
      p_reason: command.reason, p_evidence: command.evidenceReferences, p_correlation: command.correlationId,
      p_idempotency_key: command.idempotencyKey,
    });
    if (error || data === null) throw error ?? new Error('Investment refund reversal storage returned no result.');
    return data;
  }
  async decide(command: DecideInvestmentRefundReversalCommand) {
    const { data, error } = await supabase.rpc('decide_investment_refund_reversal', {
      p_organization: command.organizationId, p_actor: command.actorId, p_reversal: command.reversalId,
      p_decision: command.decision, p_review_reason: command.reviewReason,
      p_correlation: command.correlationId, p_idempotency_key: command.idempotencyKey,
    });
    if (error || data === null) throw error ?? new Error('Investment refund reversal decision returned no result.');
    return data;
  }
}
export class InvestmentRefundReversalValidationError extends Error {
  constructor(message: string) { super(message); this.name = 'InvestmentRefundReversalValidationError'; }
}
export class InvestmentRefundReversalService {
  constructor(private readonly gateway: InvestmentRefundReversalGateway = new SupabaseInvestmentRefundReversalGateway()) {}
  propose(command: ProposeInvestmentRefundReversalCommand) {
    this.ids(command.organizationId, command.actorId, command.obligationId, command.correlationId);
    if (command.providerName.trim().length < 2 || !['deterministic', 'sandbox', 'live'].includes(command.providerEnvironment)
      || command.providerReversalReference.trim().length < 4 || command.providerReversalReference.trim().length > 200
      || !HASH.test(command.providerEventHash) || !Number.isSafeInteger(command.amountMinor) || command.amountMinor <= 0
      || !/^[A-Za-z]{3}$/.test(command.currency.trim()) || !Number.isFinite(Date.parse(command.occurredAt))
      || command.reason.trim().length < 12 || command.reason.trim().length > 500
      || !Array.isArray(command.evidenceReferences) || command.evidenceReferences.length === 0) {
      throw new InvestmentRefundReversalValidationError('Investment refund reversal evidence is invalid.');
    }
    this.key(command.idempotencyKey);
    return this.gateway.propose({ ...command, providerName: command.providerName.trim().toLowerCase(),
      providerReversalReference: command.providerReversalReference.trim(), currency: command.currency.trim().toUpperCase(),
      reason: command.reason.trim() });
  }
  decide(command: DecideInvestmentRefundReversalCommand) {
    this.ids(command.organizationId, command.actorId, command.reversalId, command.correlationId);
    if (!['approve', 'reject'].includes(command.decision)
      || command.reviewReason.trim().length < 12 || command.reviewReason.trim().length > 500) {
      throw new InvestmentRefundReversalValidationError('Investment refund reversal decision is invalid.');
    }
    this.key(command.idempotencyKey);
    return this.gateway.decide({ ...command, reviewReason: command.reviewReason.trim() });
  }
  private ids(...values: string[]) {
    if (values.some((value) => !UUID.test(value))) throw new InvestmentRefundReversalValidationError('Investment refund reversal identity is invalid.');
  }
  private key(value: string) {
    if (typeof value !== 'string' || value.length < 8 || value.length > 160) throw new InvestmentRefundReversalValidationError('Investment refund reversal idempotency key is invalid.');
  }
}
export const investmentRefundReversalService = new InvestmentRefundReversalService();
