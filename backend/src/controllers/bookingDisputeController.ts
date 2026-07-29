import crypto from 'crypto';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import {
  BOOKING_DISPUTE_REASONS,
  BOOKING_DISPUTE_REMEDIES,
  BOOKING_EVIDENCE_TYPES,
  BOOKING_EVIDENCE_VISIBILITIES,
  BookingDisputeReason,
  BookingDisputeRemedy,
  BookingEvidenceType,
  BookingEvidenceVisibility,
  isDisputeNarrativeValid,
  isFileEvidence,
} from '../domains/booking/disputeRules.js';
import {
  BookingDisputeError,
  bookingDisputeService,
} from '../services/bookingDisputeService.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;

const failure = (res: Response, error: unknown) => {
  if (error instanceof BookingDisputeError) {
    return res.status(error.status).json({ success: false, error: error.code });
  }
  return res.status(503).json({ success: false, error: 'BOOKING_DISPUTE_SERVICE_UNAVAILABLE' });
};

const idempotencyKey = (req: TenantRequest): string =>
  String(req.headers['idempotency-key'] ?? '');

const validIdempotencyKey = (key: string): boolean =>
  key.length >= 8 && key.length <= 160;

const correlationId = (req: TenantRequest): string => {
  const candidate = req.headers['x-correlation-id'];
  return typeof candidate === 'string' && UUID_PATTERN.test(candidate)
    ? candidate
    : crypto.randomUUID();
};

export const openBookingDispute = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  const reason = req.body.reason_code as BookingDisputeReason;
  const remedy = req.body.requested_remedy as BookingDisputeRemedy;
  if (!UUID_PATTERN.test(req.params.id)
    || !validIdempotencyKey(key)
    || !BOOKING_DISPUTE_REASONS.includes(reason)
    || typeof req.body.narrative !== 'string'
    || !isDisputeNarrativeValid(reason, req.body.narrative)
    || !BOOKING_DISPUTE_REMEDIES.includes(remedy)
    || !Number.isSafeInteger(req.body.contested_amount_minor)
    || req.body.contested_amount_minor <= 0
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_REQUEST_INVALID' });

  const correlation = correlationId(req);
  try {
    const data = await bookingDisputeService.open({
      bookingId: req.params.id,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      reasonCode: reason,
      narrative: req.body.narrative.trim(),
      requestedRemedy: remedy,
      contestedAmountMinor: req.body.contested_amount_minor,
      idempotencyKey: key,
      correlationId: correlation,
    });
    return res.status(201).json({ success: true, data, correlation_id: correlation });
  } catch (error) {
    return failure(res, error);
  }
};

export const addBookingDisputeEvidence = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = idempotencyKey(req);
  const type = req.body.evidence_type as BookingEvidenceType;
  const visibility = (req.body.visibility ?? 'both') as BookingEvidenceVisibility;
  const file = BOOKING_EVIDENCE_TYPES.includes(type) && isFileEvidence(type);
  const body = typeof req.body.body === 'string' ? req.body.body.trim() : null;
  const objectKey = typeof req.body.storage_object_key === 'string'
    ? req.body.storage_object_key
    : null;
  const mediaType = typeof req.body.media_type === 'string' ? req.body.media_type : null;
  const sha256 = typeof req.body.sha256 === 'string' ? req.body.sha256 : null;
  const scanStatus = req.body.malware_scan_status
    ?? (file ? 'pending' : 'not_applicable');
  const supersedes = req.body.supersedes_evidence_id ?? null;

  if (!UUID_PATTERN.test(req.params.disputeId)
    || !validIdempotencyKey(key)
    || !BOOKING_EVIDENCE_TYPES.includes(type)
    || !BOOKING_EVIDENCE_VISIBILITIES.includes(visibility)
    || (supersedes !== null && (
      typeof supersedes !== 'string' || !UUID_PATTERN.test(supersedes)
    ))
    || (!file && (
      body === null || body.length < 2 || body.length > 4_000
      || objectKey !== null || mediaType !== null || sha256 !== null
      || scanStatus !== 'not_applicable'
    ))
    || (file && (
      objectKey === null || objectKey.length < 8 || objectKey.length > 1_024
      || mediaType === null || mediaType.length < 3 || mediaType.length > 160
      || sha256 === null || !SHA256_PATTERN.test(sha256)
      || !['pending', 'clean', 'rejected'].includes(scanStatus)
    ))
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_EVIDENCE_INVALID' });

  const correlation = correlationId(req);
  try {
    const data = await bookingDisputeService.addEvidence({
      disputeId: req.params.disputeId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      evidenceType: type,
      body,
      storageObjectKey: objectKey,
      mediaType,
      sha256,
      malwareScanStatus: scanStatus,
      visibility,
      supersedesEvidenceId: supersedes,
      idempotencyKey: key,
      correlationId: correlation,
    });
    return res.status(201).json({ success: true, data, correlation_id: correlation });
  } catch (error) {
    return failure(res, error);
  }
};

export const getBookingDisputeTimeline = async (
  req: TenantRequest,
  res: Response,
) => {
  if (!UUID_PATTERN.test(req.params.id)) {
    return res.status(400).json({ success: false, error: 'BOOKING_ID_INVALID' });
  }
  try {
    const data = await bookingDisputeService.readTimeline(
      req.params.id,
      req.tenant!.id,
      req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};
