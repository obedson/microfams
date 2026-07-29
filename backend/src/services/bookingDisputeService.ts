import { supabase } from '../utils/supabase.js';
import {
  BookingDisputeReason,
  BookingDisputeRemedy,
  BookingEvidenceType,
  BookingEvidenceVisibility,
} from '../domains/booking/disputeRules.js';

const ERROR_MAPPING: ReadonlyArray<readonly [string, string, number]> = [
  ['BOOKING_DISPUTE_REQUEST_INVALID', 'BOOKING_DISPUTE_REQUEST_INVALID', 400],
  ['BOOKING_DISPUTE_EVIDENCE_INVALID', 'BOOKING_DISPUTE_EVIDENCE_INVALID', 400],
  ['BOOKING_DISPUTE_NOT_AUTHORIZED', 'BOOKING_DISPUTE_NOT_AUTHORIZED', 403],
  ['BOOKING_DISPUTE_TENANT_SCOPE_INVALID', 'BOOKING_DISPUTE_NOT_AUTHORIZED', 403],
  ['BOOKING_DISPUTE_NOT_FOUND', 'BOOKING_DISPUTE_NOT_FOUND', 404],
  ['BOOKING_DISPUTE_SETTLEMENT_NOT_FOUND', 'BOOKING_DISPUTE_NOT_FOUND', 404],
  ['IDEMPOTENCY_REPLAY_CONFLICT', 'IDEMPOTENCY_REPLAY_CONFLICT', 409],
  ['BOOKING_DISPUTE_PAYMENT_NOT_ELIGIBLE', 'BOOKING_DISPUTE_PAYMENT_NOT_ELIGIBLE', 409],
  ['BOOKING_DISPUTE_SETTLEMENT_NOT_ELIGIBLE', 'BOOKING_DISPUTE_SETTLEMENT_NOT_ELIGIBLE', 409],
  ['BOOKING_DISPUTE_WINDOW_CLOSED', 'BOOKING_DISPUTE_WINDOW_CLOSED', 409],
  ['BOOKING_DISPUTE_AMOUNT_EXCEEDS_AVAILABLE', 'BOOKING_DISPUTE_AMOUNT_EXCEEDS_AVAILABLE', 409],
  ['BOOKING_DISPUTE_EVIDENCE_WINDOW_CLOSED', 'BOOKING_DISPUTE_EVIDENCE_WINDOW_CLOSED', 409],
  ['BOOKING_DISPUTE_EVIDENCE_VERSION_INVALID', 'BOOKING_DISPUTE_EVIDENCE_VERSION_INVALID', 409],
];

export class BookingDisputeError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

const mapDatabaseError = (error: { message?: string } | null): BookingDisputeError => {
  const message = error?.message ?? '';
  const mapped = ERROR_MAPPING.find(([needle]) => message.includes(needle));
  return mapped
    ? new BookingDisputeError(mapped[1], mapped[2])
    : new BookingDisputeError('BOOKING_DISPUTE_COMMAND_FAILED', 503);
};

export const bookingDisputeService = {
  async open(input: {
    bookingId: string;
    organizationId: string;
    actorId: string;
    reasonCode: BookingDisputeReason;
    narrative: string;
    requestedRemedy: BookingDisputeRemedy;
    contestedAmountMinor: number;
    idempotencyKey: string;
    correlationId: string;
  }) {
    const { data, error } = await supabase.rpc('open_booking_dispute', {
      p_booking_id: input.bookingId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_reason_code: input.reasonCode,
      p_narrative: input.narrative,
      p_requested_remedy: input.requestedRemedy,
      p_contested_amount_minor: input.contestedAmountMinor,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async addEvidence(input: {
    disputeId: string;
    organizationId: string;
    actorId: string;
    evidenceType: BookingEvidenceType;
    body: string | null;
    storageObjectKey: string | null;
    mediaType: string | null;
    sha256: string | null;
    malwareScanStatus: 'not_applicable' | 'pending' | 'clean' | 'rejected';
    visibility: BookingEvidenceVisibility;
    supersedesEvidenceId: string | null;
    idempotencyKey: string;
    correlationId: string;
  }) {
    const { data, error } = await supabase.rpc('add_booking_dispute_evidence', {
      p_dispute_id: input.disputeId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_evidence_type: input.evidenceType,
      p_body: input.body,
      p_storage_object_key: input.storageObjectKey,
      p_media_type: input.mediaType,
      p_sha256: input.sha256,
      p_malware_scan_status: input.malwareScanStatus,
      p_visibility: input.visibility,
      p_supersedes_evidence_id: input.supersedesEvidenceId,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async readTimeline(bookingId: string, organizationId: string, actorId: string) {
    const { data, error } = await supabase.rpc('read_booking_dispute_timeline', {
      p_booking_id: bookingId,
      p_acting_organization_id: organizationId,
      p_actor_id: actorId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },
};
