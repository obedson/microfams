export interface BookingFeeRuleInput {
  fixedAmountMinor: number;
  basisPoints: number;
  minimumAmountMinor: number;
  maximumAmountMinor?: number | null;
}

const assertSafeNonNegativeInteger = (value: number, name: string): void => {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative safe integer`);
  }
};

export const calculateBookingFeeMinor = (
  releaseBaseMinor: number,
  rule: BookingFeeRuleInput,
): number => {
  assertSafeNonNegativeInteger(releaseBaseMinor, 'releaseBaseMinor');
  assertSafeNonNegativeInteger(rule.fixedAmountMinor, 'fixedAmountMinor');
  assertSafeNonNegativeInteger(rule.basisPoints, 'basisPoints');
  assertSafeNonNegativeInteger(rule.minimumAmountMinor, 'minimumAmountMinor');
  if (rule.basisPoints > 10_000) throw new Error('basisPoints must not exceed 10000');
  if (rule.maximumAmountMinor !== undefined && rule.maximumAmountMinor !== null) {
    assertSafeNonNegativeInteger(rule.maximumAmountMinor, 'maximumAmountMinor');
    if (rule.maximumAmountMinor < rule.minimumAmountMinor) {
      throw new Error('maximumAmountMinor must not be less than minimumAmountMinor');
    }
  }
  if (releaseBaseMinor === 0) return 0;

  const base = BigInt(releaseBaseMinor);
  const proportional = ((base * BigInt(rule.basisPoints)) + 5_000n) / 10_000n;
  let fee = BigInt(rule.fixedAmountMinor) + proportional;
  const minimum = BigInt(rule.minimumAmountMinor);
  if (fee < minimum) fee = minimum;
  if (rule.maximumAmountMinor !== undefined && rule.maximumAmountMinor !== null) {
    const maximum = BigInt(rule.maximumAmountMinor);
    if (fee > maximum) fee = maximum;
  }
  if (fee > base) fee = base;
  const result = Number(fee);
  if (!Number.isSafeInteger(result)) throw new Error('calculated fee exceeds safe integer range');
  return result;
};

export const calculateIncrementalBookingFeeMinor = (
  previousReleaseBaseMinor: number,
  additionalReleaseBaseMinor: number,
  rule: BookingFeeRuleInput,
): number => {
  assertSafeNonNegativeInteger(previousReleaseBaseMinor, 'previousReleaseBaseMinor');
  assertSafeNonNegativeInteger(additionalReleaseBaseMinor, 'additionalReleaseBaseMinor');
  const total = previousReleaseBaseMinor + additionalReleaseBaseMinor;
  if (!Number.isSafeInteger(total)) throw new Error('cumulative release base exceeds safe integer range');
  return calculateBookingFeeMinor(total, rule) - calculateBookingFeeMinor(previousReleaseBaseMinor, rule);
};
