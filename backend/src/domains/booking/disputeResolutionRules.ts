export const BOOKING_DISPUTE_TRANSITIONS = [
  'evidence_collection',
  'under_review',
  'withdrawn',
  'closed',
] as const;

export type BookingDisputeTransition = typeof BOOKING_DISPUTE_TRANSITIONS[number];

export interface DisputeResolutionAllocation {
  customerRefundMinor: number;
  supplierReleaseMinor: number;
  platformFeeMinor: number;
  recoverableAmountMinor: number;
  lossAmountMinor: number;
}

export const isMinorAmount = (value: unknown): value is number =>
  Number.isSafeInteger(value) && Number(value) >= 0;

export const allocationTotal = (allocation: DisputeResolutionAllocation): number =>
  allocation.customerRefundMinor
    + allocation.supplierReleaseMinor
    + allocation.platformFeeMinor
    + allocation.recoverableAmountMinor
    + allocation.lossAmountMinor;

export const isConservedAllocation = (
  allocation: DisputeResolutionAllocation,
  contestedAmountMinor: number,
): boolean =>
  isMinorAmount(contestedAmountMinor)
    && Object.values(allocation).every(isMinorAmount)
    && allocationTotal(allocation) === contestedAmountMinor;

export const cumulativeFeeIncrement = (input: {
  priorReleasedBaseMinor: number;
  priorPlatformFeeMinor: number;
  releaseBaseMinor: number;
  fixedAmountMinor: number;
  basisPoints: number;
  minimumAmountMinor: number;
  maximumAmountMinor: number | null;
}): number => {
  if (input.releaseBaseMinor === 0) return 0;
  const cumulativeBase = input.priorReleasedBaseMinor + input.releaseBaseMinor;
  const variable = Math.floor((cumulativeBase * input.basisPoints) / 10_000);
  const uncapped = Math.max(input.fixedAmountMinor + variable, input.minimumAmountMinor);
  const cumulativeFee = input.maximumAmountMinor === null
    ? uncapped
    : Math.min(uncapped, input.maximumAmountMinor);
  return Math.min(
    input.releaseBaseMinor,
    Math.max(cumulativeFee - input.priorPlatformFeeMinor, 0),
  );
};
