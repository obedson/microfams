import {
  allocationTotal,
  cumulativeFeeIncrement,
  isConservedAllocation,
} from './disputeResolutionRules.js';

describe('booking dispute resolution rules', () => {
  const split = {
    customerRefundMinor: 20_000,
    supplierReleaseMinor: 16_000,
    platformFeeMinor: 4_000,
    recoverableAmountMinor: 0,
    lossAmountMinor: 0,
  };

  it('conserves every proposed disposition exactly', () => {
    expect(allocationTotal(split)).toBe(40_000);
    expect(isConservedAllocation(split, 40_000)).toBe(true);
    expect(isConservedAllocation({ ...split, lossAmountMinor: 1 }, 40_000)).toBe(false);
  });

  it('rejects negative, fractional and unsafe integer amounts', () => {
    expect(isConservedAllocation({ ...split, lossAmountMinor: -1 }, 39_999)).toBe(false);
    expect(isConservedAllocation({ ...split, lossAmountMinor: 0.5 }, 40_000.5)).toBe(false);
    expect(isConservedAllocation({
      ...split,
      customerRefundMinor: Number.MAX_SAFE_INTEGER + 1,
    }, Number.MAX_SAFE_INTEGER)).toBe(false);
  });

  it('charges only the cumulative fee increment across partial releases', () => {
    expect(cumulativeFeeIncrement({
      priorReleasedBaseMinor: 0,
      priorPlatformFeeMinor: 0,
      releaseBaseMinor: 40_000,
      fixedAmountMinor: 0,
      basisPoints: 1_000,
      minimumAmountMinor: 0,
      maximumAmountMinor: null,
    })).toBe(4_000);
    expect(cumulativeFeeIncrement({
      priorReleasedBaseMinor: 40_000,
      priorPlatformFeeMinor: 4_000,
      releaseBaseMinor: 60_000,
      fixedAmountMinor: 0,
      basisPoints: 1_000,
      minimumAmountMinor: 0,
      maximumAmountMinor: null,
    })).toBe(6_000);
  });

  it('never charges more than the current release base', () => {
    expect(cumulativeFeeIncrement({
      priorReleasedBaseMinor: 0,
      priorPlatformFeeMinor: 0,
      releaseBaseMinor: 100,
      fixedAmountMinor: 500,
      basisPoints: 0,
      minimumAmountMinor: 0,
      maximumAmountMinor: null,
    })).toBe(100);
  });
});
