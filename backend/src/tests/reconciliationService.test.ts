import { reconcilePayoutCandidates } from '../domains/financial/reconciliationService.js';

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
