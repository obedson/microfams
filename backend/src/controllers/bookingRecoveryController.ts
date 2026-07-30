import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import {
  BookingRecoveryError,
  bookingRecoveryService,
} from '../services/bookingRecoveryService.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CURRENCY = /^[A-Z]{3}$/;
const METHODS = new Set([
  'supplier_repayment',
  'provider_recovery',
  'insurance',
  'future_settlement_offset',
  'writeoff',
]);
const keyOf = (req: TenantRequest) =>
  String(req.headers['idempotency-key'] ?? '');
const validKey = (value: string) => value.length >= 8 && value.length <= 160;
const validText = (value: unknown, minimum: number, maximum: number) =>
  typeof value === 'string'
  && value.trim().length >= minimum
  && value.trim().length <= maximum;
const validDate = (value: unknown) =>
  typeof value === 'string' && !Number.isNaN(Date.parse(value));
const failure = (res: Response, error: unknown) => {
  if (error instanceof BookingRecoveryError) {
    return res.status(error.status).json({ success: false, error: error.code });
  }
  return res.status(503).json({
    success: false,
    error: 'BOOKING_RECOVERY_UNAVAILABLE',
  });
};

export const proposeBookingRecoveryOffsetAgreement = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!validKey(key)
    || typeof req.body.provider_organization_id !== 'string'
    || !UUID.test(req.body.provider_organization_id)
    || typeof req.body.currency !== 'string'
    || !CURRENCY.test(req.body.currency)
    || !Number.isSafeInteger(req.body.maximum_amount_minor)
    || req.body.maximum_amount_minor <= 0
    || !validDate(req.body.effective_from)
    || !validDate(req.body.effective_until)
    || Date.parse(req.body.effective_until) <= Date.parse(req.body.effective_from)
    || !validText(req.body.reason, 10, 500)
    || !validText(req.body.evidence_reference, 4, 500)
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_RECOVERY_OFFSET_AGREEMENT_INVALID',
  });
  try {
    const data = await bookingRecoveryService.proposeOffsetAgreement({
      organizationId: req.tenant!.id,
      providerOrganizationId: req.body.provider_organization_id,
      actorId: req.user!.id,
      currency: req.body.currency,
      maximumAmountMinor: req.body.maximum_amount_minor,
      effectiveFrom: req.body.effective_from,
      effectiveUntil: req.body.effective_until,
      reason: req.body.reason.trim(),
      evidenceReference: req.body.evidence_reference.trim(),
      idempotencyKey: key,
    });
    return res.status(201).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

const decide = async (
  req: TenantRequest,
  res: Response,
  kind: 'agreement' | 'action',
) => {
  const id = kind === 'agreement' ? req.params.agreementId : req.params.actionId;
  if (!UUID.test(id)
    || typeof req.body.approve !== 'boolean'
    || !validText(req.body.reason, 10, 500)
  ) return res.status(400).json({
    success: false,
    error: kind === 'agreement'
      ? 'BOOKING_RECOVERY_OFFSET_DECISION_INVALID'
      : 'BOOKING_RECOVERY_DECISION_INVALID',
  });
  try {
    const common = {
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      approve: req.body.approve,
      reason: req.body.reason.trim(),
    };
    const data = kind === 'agreement'
      ? await bookingRecoveryService.decideOffsetAgreement({
        ...common,
        agreementId: id,
      })
      : await bookingRecoveryService.decideAction({
        ...common,
        actionId: id,
      });
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const decideBookingRecoveryOffsetAgreement = (
  req: TenantRequest,
  res: Response,
) => decide(req, res, 'agreement');

export const proposeBookingRecoveryAction = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  const method = req.body.method;
  const offsetAgreementId = req.body.offset_agreement_id ?? null;
  const settlementReleaseId = req.body.settlement_release_id ?? null;
  const isOffset = method === 'future_settlement_offset';
  if (!UUID.test(req.params.caseId)
    || !validKey(key)
    || typeof method !== 'string'
    || !METHODS.has(method)
    || !Number.isSafeInteger(req.body.amount_minor)
    || req.body.amount_minor <= 0
    || !validText(req.body.reason, 10, 500)
    || !validText(req.body.evidence_reference, 4, 500)
    || (isOffset
      ? (typeof offsetAgreementId !== 'string'
        || !UUID.test(offsetAgreementId)
        || typeof settlementReleaseId !== 'string'
        || !UUID.test(settlementReleaseId))
      : (offsetAgreementId !== null || settlementReleaseId !== null))
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_RECOVERY_ACTION_INVALID',
  });
  try {
    const data = await bookingRecoveryService.proposeAction({
      recoveryCaseId: req.params.caseId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      method,
      amountMinor: req.body.amount_minor,
      offsetAgreementId,
      settlementReleaseId,
      evidenceReference: req.body.evidence_reference.trim(),
      reason: req.body.reason.trim(),
      idempotencyKey: key,
    });
    return res.status(201).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const decideBookingRecoveryAction = (
  req: TenantRequest,
  res: Response,
) => decide(req, res, 'action');
