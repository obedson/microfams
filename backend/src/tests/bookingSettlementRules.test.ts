import fc from 'fast-check';
import {
  calculateBookingFeeMinor,
  calculateIncrementalBookingFeeMinor,
} from '../domains/booking/settlementRules.js';

describe('booking settlement fee rules', () => {
  it('uses integer half-up rounding for basis points', () => {
    expect(calculateBookingFeeMinor(10_050, {
      fixedAmountMinor: 0,
      basisPoints: 100,
      minimumAmountMinor: 0,
    })).toBe(101);
    expect(calculateBookingFeeMinor(10_049, {
      fixedAmountMinor: 0,
      basisPoints: 100,
      minimumAmountMinor: 0,
    })).toBe(100);
  });

  it('applies fixed, minimum, maximum, and release-base caps in order', () => {
    expect(calculateBookingFeeMinor(100_000, {
      fixedAmountMinor: 100,
      basisPoints: 1_000,
      minimumAmountMinor: 500,
      maximumAmountMinor: 8_000,
    })).toBe(8_000);
    expect(calculateBookingFeeMinor(300, {
      fixedAmountMinor: 500,
      basisPoints: 0,
      minimumAmountMinor: 500,
      maximumAmountMinor: 1_000,
    })).toBe(300);
  });

  it('calculates cumulative fee deltas without applying fixed fees twice', () => {
    const rule = {
      fixedAmountMinor: 100,
      basisPoints: 250,
      minimumAmountMinor: 0,
      maximumAmountMinor: null,
    };
    expect(calculateIncrementalBookingFeeMinor(10_000, 10_000, rule))
      .toBe(calculateBookingFeeMinor(20_000, rule) - calculateBookingFeeMinor(10_000, rule));
  });

  it('never returns a negative fee or more than the releasable base', () => {
    fc.assert(fc.property(
      fc.integer({ min: 0, max: Number.MAX_SAFE_INTEGER }),
      fc.integer({ min: 0, max: 1_000_000 }),
      fc.integer({ min: 0, max: 10_000 }),
      (base, fixed, basisPoints) => {
        const fee = calculateBookingFeeMinor(base, {
          fixedAmountMinor: fixed,
          basisPoints,
          minimumAmountMinor: 0,
        });
        expect(Number.isSafeInteger(fee)).toBe(true);
        expect(fee).toBeGreaterThanOrEqual(0);
        expect(fee).toBeLessThanOrEqual(base);
      },
    ));
  });

  it('rejects invalid and unsafe rule inputs', () => {
    expect(() => calculateBookingFeeMinor(100, {
      fixedAmountMinor: 0,
      basisPoints: 10_001,
      minimumAmountMinor: 0,
    })).toThrow('basisPoints');
    expect(() => calculateBookingFeeMinor(100, {
      fixedAmountMinor: 0,
      basisPoints: 0,
      minimumAmountMinor: 20,
      maximumAmountMinor: 10,
    })).toThrow('maximumAmountMinor');
  });
});
