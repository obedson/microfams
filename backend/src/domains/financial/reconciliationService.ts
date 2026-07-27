import { supabase } from '../../utils/supabase.js';

export interface ReconciliationCandidate {
  providerReference: string;
  internalReference: string;
  amountMinor: number;
  currency: string;
  direction: 'inbound' | 'outbound';
  occurredAt: string;
}

export interface InternalPayoutCandidate extends ReconciliationCandidate {
  payoutId: string;
}

export interface InternalPaymentCandidate extends ReconciliationCandidate {
  paymentId: string;
}

export type ReconciliationMatchState = 'matched' | 'unmatched' | 'mismatch' | 'duplicate' | 'late';

export interface ReconciliationMatch {
  source: ReconciliationCandidate;
  payoutId?: string;
  state: ReconciliationMatchState;
  paymentId?: string;
  reason?: string;
}

const exactIdentity = (item: ReconciliationCandidate): string =>
  `${item.providerReference}|${item.internalReference}|${item.currency}|${item.direction}`;

export const reconcilePayoutCandidates = (
  internal: readonly (InternalPayoutCandidate | InternalPaymentCandidate)[],
  provider: readonly ReconciliationCandidate[],
  dateWindowHours: number,
): ReconciliationMatch[] => {
  if (!Number.isInteger(dateWindowHours) || dateWindowHours < 1) throw new Error('Reconciliation date window is invalid');
  const internalByIdentity = new Map(internal.map((item) => [exactIdentity(item), item]));
  const seen = new Set<string>();
  return provider.map((source) => {
    const identity = exactIdentity(source);
    if (seen.has(identity)) return { source, state: 'duplicate', reason: 'Duplicate provider identity' };
    seen.add(identity);
    const candidate = internalByIdentity.get(identity);
    if (!candidate) return { source, state: 'unmatched', reason: 'No exact internal reference match' };
    if (candidate.amountMinor !== source.amountMinor) {
      return { source, payoutId: 'payoutId' in candidate ? candidate.payoutId : undefined,
        paymentId: 'paymentId' in candidate ? candidate.paymentId : undefined,
        state: 'mismatch', reason: 'Amount mismatch' };
    }
    const distance = Math.abs(new Date(candidate.occurredAt).getTime() - new Date(source.occurredAt).getTime());
    if (!Number.isFinite(distance) || distance > dateWindowHours * 60 * 60 * 1000) {
      return { source, payoutId: 'payoutId' in candidate ? candidate.payoutId : undefined,
        paymentId: 'paymentId' in candidate ? candidate.paymentId : undefined,
        state: 'late', reason: 'Outside approved date window' };
    }
    return { source, payoutId: 'payoutId' in candidate ? candidate.payoutId : undefined,
      paymentId: 'paymentId' in candidate ? candidate.paymentId : undefined,
      state: 'matched' };
  });
};

export class ReconciliationService {
  async run(input: {
    organizationId: string;
    configurationId: string;
    sourceHash: string;
    periodStart: string;
    periodEnd: string;
    providerItems: readonly ReconciliationCandidate[];
    startedBy: string;
    openingBalanceMinor: number;
    providerBalanceMinor: number;
  }) {
    const { data, error } = await supabase.rpc('run_payment_reconciliation', {
      p_organization_id: input.organizationId,
      p_configuration_id: input.configurationId,
      p_source_hash: input.sourceHash,
      p_period_start: input.periodStart,
      p_period_end: input.periodEnd,
      p_provider_items: input.providerItems,
      p_started_by: input.startedBy,
      p_opening_balance_minor: input.openingBalanceMinor,
      p_provider_balance_minor: input.providerBalanceMinor,
    });
    if (error || !data) throw error ?? new Error('Reconciliation run could not be stored');
    return data;
  }
  async startExceptionInvestigation(input: {
    exceptionId: string;
    actorId: string;
    reason: string;
  }) {
    const { data, error } = await supabase.rpc('start_reconciliation_exception_investigation', {
      p_exception_id: input.exceptionId,
      p_actor_id: input.actorId,
      p_reason: input.reason,
    });
    if (error || !data) {
      throw error ?? new Error('Reconciliation investigation could not be started');
    }
    return data;
  }
}

export const reconciliationService = new ReconciliationService();
