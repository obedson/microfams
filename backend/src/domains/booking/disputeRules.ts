export const BOOKING_DISPUTE_REASONS = [
  'property_unavailable',
  'property_misrepresented',
  'supplier_no_show',
  'access_denied',
  'unsafe_facilities',
  'unusable_facilities',
  'service_incomplete',
  'incorrect_amount',
  'duplicate_charge',
  'agreed_cancellation_not_honoured',
  'other',
] as const;

export const BOOKING_DISPUTE_REMEDIES = [
  'refund',
  'supplier_release',
  'split',
  'correction',
] as const;

export const BOOKING_EVIDENCE_TYPES = [
  'statement',
  'photo',
  'document',
  'message',
] as const;

export const BOOKING_EVIDENCE_VISIBILITIES = [
  'both',
  'customer',
  'provider',
  'reviewer',
] as const;

export type BookingDisputeReason = typeof BOOKING_DISPUTE_REASONS[number];
export type BookingDisputeRemedy = typeof BOOKING_DISPUTE_REMEDIES[number];
export type BookingEvidenceType = typeof BOOKING_EVIDENCE_TYPES[number];
export type BookingEvidenceVisibility = typeof BOOKING_EVIDENCE_VISIBILITIES[number];

export const availableContestedAmount = (input: {
  grossAmountMinor: number;
  refundedAmountMinor: number;
  releasedAmountMinor: number;
  alreadyContestedAmountMinor: number;
}): number => Math.max(
  0,
  input.grossAmountMinor
    - input.refundedAmountMinor
    - input.releasedAmountMinor
    - input.alreadyContestedAmountMinor,
);

export const isDisputeNarrativeValid = (
  reason: BookingDisputeReason,
  narrative: string,
): boolean => {
  const length = narrative.trim().length;
  return length >= (reason === 'other' ? 40 : 20) && length <= 2_000;
};

export const isFileEvidence = (type: BookingEvidenceType): boolean =>
  type === 'photo' || type === 'document';
