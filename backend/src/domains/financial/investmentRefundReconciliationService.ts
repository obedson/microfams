import { supabase } from '../../utils/supabase.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;

export type InvestmentRefundProviderState = 'submitted' | 'processing' | 'succeeded' | 'failed' | 'cancelled';

export interface InvestmentRefundProviderEvidence {
  internalReference: string;
  providerReference?: string;
  status: InvestmentRefundProviderState;
  amountMinor: number;
  currency: string;
  occurredAt: string;
}

export interface RunInvestmentRefundReconciliationCommand {
  organizationId: string;
  actorId: string;
  providerName: string;
  providerEnvironment: 'deterministic' | 'sandbox' | 'live';
  sourceHash: string;
  idempotencyKey: string;
  periodStart: string;
  periodEnd: string;
  providerItems: readonly InvestmentRefundProviderEvidence[];
}

export interface InvestmentRefundReconciliationGateway {
  run(command: RunInvestmentRefundReconciliationCommand): Promise<unknown>;
}

export class SupabaseInvestmentRefundReconciliationGateway implements InvestmentRefundReconciliationGateway {
  async run(command: RunInvestmentRefundReconciliationCommand) {
    const { data, error } = await supabase.rpc('run_investment_refund_reconciliation', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_provider_name: command.providerName,
      p_provider_environment: command.providerEnvironment,
      p_source_hash: command.sourceHash,
      p_idempotency_key: command.idempotencyKey,
      p_period_start: command.periodStart,
      p_period_end: command.periodEnd,
      p_provider_items: command.providerItems,
    });
    if (error || data === null) throw error ?? new Error('Investment refund reconciliation returned no result.');
    return data;
  }
}

export class InvestmentRefundReconciliationValidationError extends Error {
  constructor(message: string) { super(message); this.name = 'InvestmentRefundReconciliationValidationError'; }
}

export class InvestmentRefundReconciliationService {
  constructor(private readonly gateway: InvestmentRefundReconciliationGateway = new SupabaseInvestmentRefundReconciliationGateway()) {}

  run(command: RunInvestmentRefundReconciliationCommand) {
    this.validate(command);
    return this.gateway.run({
      ...command,
      providerName: command.providerName.trim().toLowerCase(),
      providerItems: command.providerItems.map((item) => ({
        ...item,
        internalReference: item.internalReference.trim(),
        providerReference: item.providerReference?.trim() || undefined,
        currency: item.currency.trim().toUpperCase(),
      })),
    });
  }

  private validate(command: RunInvestmentRefundReconciliationCommand) {
    if (!UUID.test(command.organizationId) || !UUID.test(command.actorId)
      || !HASH.test(command.sourceHash) || command.idempotencyKey.length < 8 || command.idempotencyKey.length > 160
      || command.providerName.trim().length < 2 || !['deterministic', 'sandbox', 'live'].includes(command.providerEnvironment)
      || !this.validDate(command.periodStart) || !this.validDate(command.periodEnd)
      || new Date(command.periodStart) >= new Date(command.periodEnd)
      || !Array.isArray(command.providerItems) || command.providerItems.length > 5000) {
      throw new InvestmentRefundReconciliationValidationError('Investment refund reconciliation command is invalid.');
    }
    for (const item of command.providerItems) {
      if (!/^investment-refund-[0-9a-f-]{36}$/i.test(item.internalReference.trim())
        || !['submitted', 'processing', 'succeeded', 'failed', 'cancelled'].includes(item.status)
        || !Number.isSafeInteger(item.amountMinor) || item.amountMinor <= 0
        || !/^[A-Za-z]{3}$/.test(item.currency.trim()) || !this.validDate(item.occurredAt)) {
        throw new InvestmentRefundReconciliationValidationError('Investment refund provider evidence is invalid.');
      }
    }
  }

  private validDate(value: string) { return typeof value === 'string' && Number.isFinite(Date.parse(value)); }
}

export const investmentRefundReconciliationService = new InvestmentRefundReconciliationService();
