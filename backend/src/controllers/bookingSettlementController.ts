import crypto from 'crypto';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import {
  BookingSettlementError,
  bookingSettlementService,
} from '../services/bookingSettlementService.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const failure = (res: Response, error: unknown) => {
  if (error instanceof BookingSettlementError) {
    return res.status(error.status).json({ success: false, error: error.code });
  }
  return res.status(503).json({ success: false, error: 'BOOKING_SETTLEMENT_SERVICE_UNAVAILABLE' });
};

const idempotencyKey = (req: TenantRequest): string =>
  String(req.headers['idempotency-key'] ?? '');

const validIdempotencyKey = (key: string): boolean =>
  key.length >= 8 && key.length <= 160;

const validEffectiveFrom = (value: unknown): value is string =>
  typeof value === 'string' && Number.isFinite(Date.parse(value));

const validReason = (value: unknown): value is string =>
  typeof value === 'string' && value.trim().length >= 10 && value.trim().length <= 500;

const safeNonNegativeInteger = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;

export const getBookingFinancialRules = async (req: TenantRequest, res: Response) => {
  try {
    const data = await bookingSettlementService.readRules(req.tenant!.id, req.user!.id);
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const proposeBookingSettlementRule = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  if (!validIdempotencyKey(key)
    || !Number.isInteger(req.body.version) || req.body.version <= 0
    || !Number.isInteger(req.body.dispute_window_hours)
    || req.body.dispute_window_hours < 0 || req.body.dispute_window_hours > 336
    || !validEffectiveFrom(req.body.effective_from)
    || !validReason(req.body.change_reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_RULE_INPUT_INVALID' });
  try {
    const data = await bookingSettlementService.proposeSettlementRule({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      version: req.body.version,
      disputeWindowHours: req.body.dispute_window_hours,
      effectiveFrom: req.body.effective_from,
      changeReason: req.body.change_reason.trim(),
      idempotencyKey: key,
    });
    return res.status(202).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const proposeBookingFeeRule = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  const maximum = req.body.maximum_amount_minor ?? null;
  const beneficiary = req.body.beneficiary_organization_id ?? null;
  const metadata = req.body.tax_withholding_metadata ?? {};
  if (!validIdempotencyKey(key)
    || !Number.isInteger(req.body.version) || req.body.version <= 0
    || typeof req.body.currency !== 'string' || !/^[A-Za-z]{3}$/.test(req.body.currency)
    || !['customer', 'supplier'].includes(req.body.payer)
    || (beneficiary !== null && (typeof beneficiary !== 'string' || !UUID_PATTERN.test(beneficiary)))
    || !safeNonNegativeInteger(req.body.fixed_amount_minor)
    || !safeNonNegativeInteger(req.body.basis_points) || req.body.basis_points > 10_000
    || !safeNonNegativeInteger(req.body.minimum_amount_minor)
    || (maximum !== null && !safeNonNegativeInteger(maximum))
    || (maximum !== null && maximum < req.body.minimum_amount_minor)
    || typeof metadata !== 'object' || metadata === null || Array.isArray(metadata)
    || !validEffectiveFrom(req.body.effective_from)
    || !validReason(req.body.change_reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_FEE_RULE_INPUT_INVALID' });
  try {
    const data = await bookingSettlementService.proposeFeeRule({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      version: req.body.version,
      currency: req.body.currency.toUpperCase(),
      payer: req.body.payer,
      beneficiaryOrganizationId: beneficiary,
      fixedAmountMinor: req.body.fixed_amount_minor,
      basisPoints: req.body.basis_points,
      minimumAmountMinor: req.body.minimum_amount_minor,
      maximumAmountMinor: maximum,
      taxWithholdingMetadata: metadata,
      effectiveFrom: req.body.effective_from,
      changeReason: req.body.change_reason.trim(),
      idempotencyKey: key,
    });
    return res.status(202).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const decideBookingFinancialRule = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  if (!validIdempotencyKey(key)
    || !UUID_PATTERN.test(req.params.approvalId)
    || typeof req.body.approve !== 'boolean'
    || !validReason(req.body.reason)
  ) return res.status(400).json({ success: false, error: 'BOOKING_RULE_DECISION_INPUT_INVALID' });
  try {
    const data = await bookingSettlementService.decideRule({
      approvalId: req.params.approvalId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      approve: req.body.approve,
      reason: req.body.reason.trim(),
      idempotencyKey: key,
    });
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const getBookingSettlement = async (req: TenantRequest, res: Response) => {
  if (!UUID_PATTERN.test(req.params.id)) {
    return res.status(400).json({ success: false, error: 'BOOKING_ID_INVALID' });
  }
  try {
    const data = await bookingSettlementService.read(
      req.params.id,
      req.tenant!.id,
      req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const releaseBookingSettlement = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  if (!UUID_PATTERN.test(req.params.id)) {
    return res.status(400).json({ success: false, error: 'BOOKING_ID_INVALID' });
  }
  if (!validIdempotencyKey(key)) {
    return res.status(400).json({ success: false, error: 'IDEMPOTENCY_KEY_INVALID' });
  }
  const candidate = req.headers['x-correlation-id'];
  const correlationId = typeof candidate === 'string' && UUID_PATTERN.test(candidate)
    ? candidate
    : crypto.randomUUID();
  try {
    const data = await bookingSettlementService.release({
      bookingId: req.params.id,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      idempotencyKey: key,
      correlationId,
    });
    return res.status(200).json({ success: true, data, correlation_id: correlationId });
  } catch (error) {
    return failure(res, error);
  }
};
