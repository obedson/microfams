import crypto from 'crypto';
import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { TenantRequest } from '../middleware/tenant.js';
import {
  BOOKING_DISPUTE_TRANSITIONS,
  BookingDisputeTransition,
  DisputeResolutionAllocation,
  isConservedAllocation,
  isMinorAmount,
} from '../domains/booking/disputeResolutionRules.js';
import {
  BookingDisputeResolutionError,
  bookingDisputeResolutionService,
} from '../services/bookingDisputeResolutionService.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const keyOf = (req: AuthRequest) => String(req.headers['idempotency-key'] ?? '');
const validKey = (key: string) => key.length >= 8 && key.length <= 160;
const correlationOf = (req: AuthRequest) => {
  const value = req.headers['x-correlation-id'];
  return typeof value === 'string' && UUID.test(value) ? value : crypto.randomUUID();
};
const validReason = (value: unknown, minimum = 10) =>
  typeof value === 'string' && value.trim().length >= minimum && value.trim().length <= 2_000;
const failure = (res: Response, error: unknown) => {
  if (error instanceof BookingDisputeResolutionError) {
    return res.status(error.status).json({ success: false, error: error.code });
  }
  return res.status(503).json({ success: false, error: 'BOOKING_DISPUTE_RESOLUTION_UNAVAILABLE' });
};

export const transitionBookingDispute = async (req: TenantRequest, res: Response) => {
  const key = keyOf(req);
  const targetState = req.body.target_state as BookingDisputeTransition;
  if (!UUID.test(req.params.disputeId) || !validKey(key)
    || !BOOKING_DISPUTE_TRANSITIONS.includes(targetState)
    || !validReason(req.body.reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_TRANSITION_INVALID' });
  const correlationId = correlationOf(req);
  try {
    const data = await bookingDisputeResolutionService.transition({
      disputeId: req.params.disputeId, organizationId: req.tenant!.id,
      actorId: req.user!.id, targetState, reason: req.body.reason.trim(),
      idempotencyKey: key, correlationId,
    });
    return res.json({ success: true, data, correlation_id: correlationId });
  } catch (error) { return failure(res, error); }
};

export const proposeBookingDisputeResolution = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  const allocation: DisputeResolutionAllocation = {
    customerRefundMinor: req.body.customer_refund_minor,
    supplierReleaseMinor: req.body.supplier_release_minor,
    platformFeeMinor: req.body.platform_fee_minor,
    recoverableAmountMinor: req.body.recoverable_amount_minor,
    lossAmountMinor: req.body.loss_amount_minor,
  };
  const evidenceIds = req.body.evidence_ids ?? [];
  if (!UUID.test(req.params.disputeId) || !validKey(key)
    || !validReason(req.body.reason, 20)
    || !Array.isArray(evidenceIds) || !evidenceIds.every((id) => typeof id === 'string' && UUID.test(id))
    || !isMinorAmount(req.body.contested_amount_minor)
    || !isConservedAllocation(allocation, req.body.contested_amount_minor)
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_RESOLUTION_INVALID' });
  const correlationId = correlationOf(req);
  try {
    const data = await bookingDisputeResolutionService.propose({
      disputeId: req.params.disputeId, organizationId: req.tenant!.id,
      actorId: req.user!.id, allocation, evidenceIds,
      reason: req.body.reason.trim(), idempotencyKey: key, correlationId,
    });
    return res.status(201).json({ success: true, data, correlation_id: correlationId });
  } catch (error) { return failure(res, error); }
};

export const decideBookingDisputeResolution = async (req: TenantRequest, res: Response) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.proposalId) || !validKey(key)
    || typeof req.body.approve !== 'boolean' || !validReason(req.body.reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_DECISION_INVALID' });
  const correlationId = correlationOf(req);
  try {
    const data = await bookingDisputeResolutionService.decide({
      proposalId: req.params.proposalId, organizationId: req.tenant!.id,
      actorId: req.user!.id,
      approve: req.body.approve, reason: req.body.reason.trim(),
      idempotencyKey: key, correlationId,
    });
    return res.json({ success: true, data, correlation_id: correlationId });
  } catch (error) { return failure(res, error); }
};

export const getBookingDisputeResolutionCase = async (
  req: TenantRequest,
  res: Response,
) => {
  if (!UUID.test(req.params.disputeId)) {
    return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_ID_INVALID' });
  }
  try {
    const data = await bookingDisputeResolutionService.readCase(
      req.params.disputeId, req.tenant!.id, req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) { return failure(res, error); }
};

export const proposeBookingDisputeResponseRule = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  const effectiveFrom = req.body.effective_from;
  if (!validKey(key) || !Number.isSafeInteger(req.body.version) || req.body.version <= 0
    || !Number.isSafeInteger(req.body.response_period_days)
    || req.body.response_period_days < 1 || req.body.response_period_days > 14
    || typeof effectiveFrom !== 'string' || Number.isNaN(Date.parse(effectiveFrom))
    || !validReason(req.body.change_reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_DISPUTE_RESPONSE_RULE_INVALID' });
  try {
    const data = await bookingDisputeResolutionService.proposeResponseRule({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      version: req.body.version, responsePeriodDays: req.body.response_period_days,
      effectiveFrom, changeReason: req.body.change_reason.trim(), idempotencyKey: key,
    });
    return res.status(201).json({ success: true, data });
  } catch (error) { return failure(res, error); }
};

export const decideBookingDisputeResponseRule = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.ruleId) || !validKey(key)
    || typeof req.body.approve !== 'boolean' || !validReason(req.body.reason)
  ) return res.status(400).json({
    success: false, error: 'BOOKING_DISPUTE_RESPONSE_RULE_DECISION_INVALID',
  });
  try {
    const data = await bookingDisputeResolutionService.decideResponseRule({
      ruleId: req.params.ruleId, organizationId: req.tenant!.id, actorId: req.user!.id,
      approve: req.body.approve, reason: req.body.reason.trim(), idempotencyKey: key,
    });
    return res.json({ success: true, data });
  } catch (error) { return failure(res, error); }
};
