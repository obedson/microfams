import fc from 'fast-check';
import {
  GROUP_TREASURY_DISBURSEMENT_STATES,
  assertDisbursementTransition,
  assertFundsAvailable,
  assertSeparationOfDuties,
  canTransitionDisbursement,
  summarizeTreasuryPosition,
  validateBudgetKey,
  validateDisbursementRequest,
  validateReleaseReasonCode,
} from '../domains/groups/treasuryDisbursementRules.js';

describe('group treasury disbursement rules', () => {
  const maker = '00000000-0000-4000-8000-000000000001';
  const checker = '00000000-0000-4000-8000-000000000002';
  const beneficiary = '00000000-0000-4000-8000-000000000003';
  const memberId = '00000000-0000-4000-8000-000000000010';

  const request = {
    channel: 'internal',
    beneficiaryKind: 'member',
    beneficiaryMemberId: memberId,
    amountMinor: 120_000,
    currency: 'NGN',
    purpose: 'Reimburse approved operating expenses',
    evidenceUri: 'https://evidence.example.test/receipt-1',
  };

  describe('spend requests', () => {
    it('normalizes a complete internal member request', () => {
      expect(validateDisbursementRequest(request)).toEqual({
        channel: 'internal',
        beneficiaryKind: 'member',
        beneficiaryMemberId: memberId,
        beneficiaryUserId: null,
        amountMinor: 120_000,
        currency: 'NGN',
        purpose: 'Reimburse approved operating expenses',
        evidenceUri: 'https://evidence.example.test/receipt-1',
      });
    });

    it('refuses a member payout that names no member', () => {
      expect(() => validateDisbursementRequest({
        ...request, beneficiaryMemberId: null,
      })).toThrow('GROUP_TREASURY_BENEFICIARY_MEMBER_REQUIRED');
    });

    it('refuses a non-member payout that carries a member', () => {
      expect(() => validateDisbursementRequest({
        ...request, beneficiaryKind: 'project',
      })).toThrow('GROUP_TREASURY_BENEFICIARY_MEMBER_UNEXPECTED');
    });

    it('refuses an unknown beneficiary kind or channel', () => {
      expect(() => validateDisbursementRequest({
        ...request, beneficiaryKind: 'vendor',
      })).toThrow('GROUP_TREASURY_BENEFICIARY_KIND_INVALID');
      // The external provider channel arrives with GT-06B; until then it must be
      // refused rather than silently treated as internal.
      expect(() => validateDisbursementRequest({
        ...request, channel: 'external',
      })).toThrow('GROUP_TREASURY_CHANNEL_INVALID');
    });

    it('refuses a zero, negative, fractional, or oversized amount', () => {
      for (const amountMinor of [0, -1, 1.5, 100_000_000_001]) {
        expect(() => validateDisbursementRequest({ ...request, amountMinor }))
          .toThrow('GROUP_TREASURY_AMOUNT_INVALID');
      }
    });

    it('refuses a malformed currency and an empty purpose', () => {
      expect(() => validateDisbursementRequest({ ...request, currency: 'naira' }))
        .toThrow('GROUP_TREASURY_CURRENCY_INVALID');
      expect(() => validateDisbursementRequest({ ...request, purpose: '   ' }))
        .toThrow('GROUP_TREASURY_PURPOSE_REQUIRED');
    });
  });

  describe('separation of duties', () => {
    it('accepts three distinct people', () => {
      expect(assertSeparationOfDuties({
        requestedByUserId: maker,
        checkerUserId: checker,
        beneficiaryUserId: beneficiary,
      })).toBe(true);
    });

    it('refuses the maker approving their own request', () => {
      expect(() => assertSeparationOfDuties({
        requestedByUserId: maker, checkerUserId: maker,
      })).toThrow('GROUP_TREASURY_MAKER_CANNOT_CHECK');
    });

    it('refuses the beneficiary standing as maker or checker', () => {
      expect(() => assertSeparationOfDuties({
        requestedByUserId: beneficiary,
        checkerUserId: checker,
        beneficiaryUserId: beneficiary,
      })).toThrow('GROUP_TREASURY_BENEFICIARY_CANNOT_REQUEST');

      expect(() => assertSeparationOfDuties({
        requestedByUserId: maker,
        checkerUserId: beneficiary,
        beneficiaryUserId: beneficiary,
      })).toThrow('GROUP_TREASURY_BENEFICIARY_CANNOT_CHECK');
    });

    it('never accepts a pair of identical actors', () => {
      fc.assert(fc.property(
        fc.constantFrom(maker, checker, beneficiary),
        (actor) => {
          expect(() => assertSeparationOfDuties({
            requestedByUserId: actor, checkerUserId: actor,
          })).toThrow();
        },
      ));
    });
  });

  describe('funds availability', () => {
    it('accepts a spend within available funds', () => {
      expect(assertFundsAvailable({ availableMinor: 500_000, amountMinor: 120_000 }))
        .toBe(true);
    });

    it('refuses a spend beyond available funds', () => {
      expect(() => assertFundsAvailable({ availableMinor: 50_000, amountMinor: 120_000 }))
        .toThrow('GROUP_TREASURY_INSUFFICIENT_FUNDS');
    });

    it('refuses a spend beyond the budget even when the treasury could cover it', () => {
      expect(() => assertFundsAvailable({
        availableMinor: 500_000, amountMinor: 120_000, budgetRemainingMinor: 100_000,
      })).toThrow('GROUP_TREASURY_BUDGET_EXCEEDED');
    });

    it('never accepts an amount larger than what is available', () => {
      fc.assert(fc.property(
        fc.integer({ min: 0, max: 1_000_000 }),
        fc.integer({ min: 1, max: 1_000_000 }),
        (availableMinor, amountMinor) => {
          let accepted = true;
          try {
            assertFundsAvailable({ availableMinor, amountMinor });
          } catch {
            accepted = false;
          }
          if (accepted) expect(amountMinor).toBeLessThanOrEqual(availableMinor);
        },
      ));
    });
  });

  describe('disbursement transitions', () => {
    it('allows only the documented edges', () => {
      expect(canTransitionDisbursement('requested', 'approved')).toBe(true);
      expect(canTransitionDisbursement('approved', 'executed')).toBe(true);
      expect(canTransitionDisbursement('executed', 'reversed')).toBe(true);
      // Money may not move without a countersignature.
      expect(canTransitionDisbursement('requested', 'executed')).toBe(false);
      // An executed payment is corrected by reversal, never un-approved.
      expect(canTransitionDisbursement('executed', 'approved')).toBe(false);
      expect(() => assertDisbursementTransition('rejected', 'approved'))
        .toThrow('GROUP_TREASURY_DISBURSEMENT_TRANSITION_INVALID');
    });

    it('treats rejected, cancelled, expired, and reversed as terminal', () => {
      fc.assert(fc.property(
        fc.constantFrom('rejected', 'cancelled', 'expired', 'reversed'),
        fc.constantFrom(...GROUP_TREASURY_DISBURSEMENT_STATES),
        (from, to) => {
          expect(canTransitionDisbursement(from, to)).toBe(false);
        },
      ));
    });
  });

  describe('reason codes and budget keys', () => {
    it('accepts uppercase reason codes and rejects lowercase', () => {
      expect(validateReleaseReasonCode('ABANDONED')).toBe('ABANDONED');
      expect(() => validateReleaseReasonCode('abandoned'))
        .toThrow('GROUP_TREASURY_REASON_CODE_INVALID');
    });

    it('accepts hyphenated budget keys the schema permits', () => {
      expect(validateBudgetKey('ops-2026q3')).toBe('ops-2026q3');
      expect(validateBudgetKey('ops_neg')).toBe('ops_neg');
      expect(() => validateBudgetKey('Ops-2026'))
        .toThrow('GROUP_TREASURY_BUDGET_KEY_INVALID');
    });
  });

  describe('treasury position', () => {
    it('derives available as balance minus reservations', () => {
      expect(summarizeTreasuryPosition({ balanceMinor: 500_000, reservedMinor: 120_000 }))
        .toEqual({ balanceMinor: 500_000, reservedMinor: 120_000, availableMinor: 380_000 });
    });

    it('never reports negative available funds', () => {
      expect(summarizeTreasuryPosition({ balanceMinor: 10_000, reservedMinor: 50_000 }))
        .toMatchObject({ availableMinor: 0 });
    });
  });
});
