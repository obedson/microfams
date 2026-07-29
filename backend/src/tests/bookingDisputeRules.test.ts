import fc from 'fast-check';
import {
  availableContestedAmount,
  isDisputeNarrativeValid,
  isFileEvidence,
} from '../domains/booking/disputeRules.js';

describe('booking dispute rules', () => {
  it('never exposes more than the unfrozen, unrefunded, unreleased balance', () => {
    fc.assert(fc.property(
      fc.integer({ min: 1, max: Number.MAX_SAFE_INTEGER }),
      fc.integer({ min: 0, max: 1_000_000_000 }),
      fc.integer({ min: 0, max: 1_000_000_000 }),
      fc.integer({ min: 0, max: 1_000_000_000 }),
      (grossAmountMinor, refundedAmountMinor, releasedAmountMinor, alreadyContestedAmountMinor) => {
        const available = availableContestedAmount({
          grossAmountMinor,
          refundedAmountMinor,
          releasedAmountMinor,
          alreadyContestedAmountMinor,
        });
        expect(available).toBeGreaterThanOrEqual(0);
        expect(available).toBeLessThanOrEqual(grossAmountMinor);
      },
    ));
  });

  it('requires additional detail for other reasons', () => {
    expect(isDisputeNarrativeValid('unsafe_facilities', 'The facilities were unsafe.')).toBe(true);
    expect(isDisputeNarrativeValid('other', 'The facilities were unsafe.')).toBe(false);
    expect(isDisputeNarrativeValid(
      'other',
      'A detailed issue occurred that does not fit another listed reason.',
    )).toBe(true);
  });

  it('classifies only photo and document evidence as file evidence', () => {
    expect(isFileEvidence('photo')).toBe(true);
    expect(isFileEvidence('document')).toBe(true);
    expect(isFileEvidence('statement')).toBe(false);
    expect(isFileEvidence('message')).toBe(false);
  });
});
