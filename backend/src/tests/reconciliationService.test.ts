import { supabase } from '../utils/supabase.js';
import {
  ReconciliationService,
  reconcilePayoutCandidates,
} from '../domains/financial/reconciliationService.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { rpc: jest.fn() } }));
const rpcMock = supabase.rpc as jest.Mock;

const internal = [{
  payoutId: 'payout-1', providerReference: 'provider-1', internalReference: 'WD-internal-1',
  amountMinor: 100000, currency: 'NGN', direction: 'outbound' as const, occurredAt: '2026-07-19T10:00:00Z',
}];

describe('payout reconciliation matching', () => {
  it('matches only the complete approved identity within the date window', () => {
    const [match] = reconcilePayoutCandidates(internal, [{ ...internal[0] }], 24);
    expect(match).toMatchObject({ payoutId: 'payout-1', state: 'matched' });
  });

  it('never matches by amount alone', () => {
    const [match] = reconcilePayoutCandidates(internal, [{
      ...internal[0], providerReference: 'different-provider-reference', internalReference: 'different-internal-reference',
    }], 24);
    expect(match.state).toBe('unmatched');
  });

  it('classifies amount mismatch, duplicates, and late records', () => {
    const results = reconcilePayoutCandidates(internal, [
      { ...internal[0], amountMinor: 99999 },
      { ...internal[0], amountMinor: 99999 },
      { ...internal[0], occurredAt: '2026-07-22T10:00:00Z' },
    ], 24);
    expect(results.map((result) => result.state)).toEqual(['mismatch', 'duplicate', 'duplicate']);
    const [late] = reconcilePayoutCandidates(internal, [{ ...internal[0], occurredAt: '2026-07-22T10:00:00Z' }], 24);
    expect(late.state).toBe('late');
  });
});

describe('atomic reconciliation persistence', () => {
  beforeEach(() => rpcMock.mockReset());

  it('delegates the complete source batch to one atomic database command', async () => {
    rpcMock.mockResolvedValue({ data: { id: 'run-1', matchedCount: 1, exceptionCount: 0 }, error: null });
    const service = new ReconciliationService();
    const providerItems = [{
      providerReference: 'provider-1',
      internalReference: 'PAY-internal-1',
      amountMinor: 100000,
      currency: 'NGN',
      direction: 'inbound' as const,
      occurredAt: '2026-07-19T10:00:00Z',
    }];

    await expect(service.run({
      organizationId: 'organization-1',
      configurationId: 'configuration-1',
      sourceHash: 'a'.repeat(64),
      periodStart: '2026-07-19T00:00:00Z',
      periodEnd: '2026-07-20T00:00:00Z',
      providerItems,
      startedBy: 'actor-1',
      openingBalanceMinor: 0,
      providerBalanceMinor: 100000,
    })).resolves.toEqual({ id: 'run-1', matchedCount: 1, exceptionCount: 0 });

    expect(rpcMock).toHaveBeenCalledTimes(1);
    expect(rpcMock).toHaveBeenCalledWith('run_payment_reconciliation', expect.objectContaining({
      p_organization_id: 'organization-1',
      p_configuration_id: 'configuration-1',
      p_source_hash: 'a'.repeat(64),
      p_provider_items: providerItems,
      p_opening_balance_minor: 0,
      p_provider_balance_minor: 100000,
    }));
  });
});
