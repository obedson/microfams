import crypto from 'crypto';
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

export type ReconciliationMatchState = 'matched' | 'unmatched' | 'mismatch' | 'duplicate' | 'late';

export interface ReconciliationMatch {
  source: ReconciliationCandidate;
  payoutId?: string;
  state: ReconciliationMatchState;
  reason?: string;
}

const exactIdentity = (item: ReconciliationCandidate): string =>
  `${item.providerReference}|${item.internalReference}|${item.currency}|${item.direction}`;

export const reconcilePayoutCandidates = (
  internal: readonly InternalPayoutCandidate[],
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
      return { source, payoutId: candidate.payoutId, state: 'mismatch', reason: 'Amount mismatch' };
    }
    const distance = Math.abs(new Date(candidate.occurredAt).getTime() - new Date(source.occurredAt).getTime());
    if (!Number.isFinite(distance) || distance > dateWindowHours * 60 * 60 * 1000) {
      return { source, payoutId: candidate.payoutId, state: 'late', reason: 'Outside approved date window' };
    }
    return { source, payoutId: candidate.payoutId, state: 'matched' };
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
    const { data: configuration, error: configError } = await supabase
      .from('reconciliation_configurations')
      .select('*')
      .eq('id', input.configurationId)
      .eq('organization_id', input.organizationId)
      .eq('enabled', true)
      .single();
    if (configError || !configuration) throw new Error('Reconciliation configuration is unavailable');

    const { data: payouts, error: payoutError } = await supabase
      .from('payouts')
      .select('id, provider_reference, internal_reference, amount_minor, currency, terminal_at')
      .eq('organization_id', input.organizationId)
      .eq('provider_name', configuration.provider_name)
      .eq('provider_environment', configuration.provider_environment)
      .eq('state', 'succeeded')
      .gte('terminal_at', input.periodStart)
      .lte('terminal_at', input.periodEnd);
    if (payoutError) throw payoutError;
    const internal: InternalPayoutCandidate[] = (payouts ?? []).map((payout: any) => ({
      payoutId: payout.id,
      providerReference: payout.provider_reference,
      internalReference: payout.internal_reference,
      amountMinor: Number(payout.amount_minor),
      currency: payout.currency,
      direction: 'outbound',
      occurredAt: payout.terminal_at,
    }));
    const matches = reconcilePayoutCandidates(internal, input.providerItems, configuration.date_window_hours);
    const movementMinor = -internal.reduce((sum, item) => sum + item.amountMinor, 0);
    const closingBalanceMinor = input.openingBalanceMinor + movementMinor;
    const matchedValueMinor = matches.filter((item) => item.state === 'matched')
      .reduce((sum, item) => sum + item.source.amountMinor, 0);
    const unexplainedVarianceMinor = closingBalanceMinor - input.providerBalanceMinor;

    const { data: run, error: runError } = await supabase.from('reconciliation_runs').upsert({
      organization_id: input.organizationId,
      configuration_id: input.configurationId,
      source_hash: input.sourceHash,
      period_start: input.periodStart,
      period_end: input.periodEnd,
      state: 'completed',
      opening_balance_minor: input.openingBalanceMinor,
      movement_minor: movementMinor,
      closing_balance_minor: closingBalanceMinor,
      provider_balance_minor: input.providerBalanceMinor,
      matched_value_minor: matchedValueMinor,
      unexplained_variance_minor: unexplainedVarianceMinor,
      started_by: input.startedBy,
      completed_at: new Date().toISOString(),
    }, { onConflict: 'configuration_id,source_hash' }).select().single();
    if (runError || !run) throw runError ?? new Error('Reconciliation run could not be stored');

    for (const match of matches) {
      const sourceItemHash = crypto.createHash('sha256').update(JSON.stringify(match.source)).digest('hex');
      const { data: item, error: itemError } = await supabase.from('reconciliation_items').upsert({
        organization_id: input.organizationId,
        run_id: run.id,
        payout_id: match.payoutId,
        provider_reference: match.source.providerReference,
        internal_reference: match.source.internalReference,
        direction: match.source.direction,
        currency: match.source.currency,
        amount_minor: match.source.amountMinor,
        occurred_at: match.source.occurredAt,
        source_item_hash: sourceItemHash,
        state: match.state,
        mismatch_reason: match.reason,
      }, { onConflict: 'run_id,source_item_hash' }).select().single();
      if (itemError || !item) throw itemError ?? new Error('Reconciliation item could not be stored');
      if (match.state !== 'matched') {
        const { error: exceptionError } = await supabase.from('reconciliation_exceptions').upsert({
          organization_id: input.organizationId,
          run_id: run.id,
          item_id: item.id,
          reason: match.reason ?? match.state,
        }, { onConflict: 'item_id' });
        if (exceptionError) throw exceptionError;
      }
    }
    return { ...run, matchedCount: matches.filter((item) => item.state === 'matched').length, exceptionCount: matches.filter((item) => item.state !== 'matched').length };
  }
}

export const reconciliationService = new ReconciliationService();
