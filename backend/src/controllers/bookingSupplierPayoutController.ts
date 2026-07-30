import crypto from 'crypto';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import {
  BookingSupplierPayoutError,
  bookingSupplierPayoutService,
} from '../services/bookingSupplierPayoutService.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACCOUNT = /^[0-9]{10}$/;
const BANK = /^[A-Za-z0-9_-]{2,20}$/;
const keyOf = (req: TenantRequest) =>
  String(req.headers['idempotency-key'] ?? '');
const validKey = (key: string) => key.length >= 8 && key.length <= 160;
const correlationOf = (req: TenantRequest) => {
  const candidate = req.headers['x-correlation-id'];
  return typeof candidate === 'string' && UUID.test(candidate)
    ? candidate
    : crypto.randomUUID();
};
const failure = (res: Response, error: unknown) => {
  if (error instanceof BookingSupplierPayoutError) {
    return res.status(error.status).json({ success: false, error: error.code });
  }
  return res.status(503).json({
    success: false,
    error: 'BOOKING_SUPPLIER_PAYOUT_UNAVAILABLE',
  });
};

export const registerBookingPayoutBeneficiary = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  const beneficiaryUserId = req.body.beneficiary_user_id ?? null;
  if (!validKey(key)
    || typeof req.body.account_number !== 'string'
    || !ACCOUNT.test(req.body.account_number)
    || typeof req.body.bank_code !== 'string'
    || !BANK.test(req.body.bank_code)
    || (beneficiaryUserId !== null && (
      typeof beneficiaryUserId !== 'string' || !UUID.test(beneficiaryUserId)
    ))
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_PAYOUT_BENEFICIARY_INVALID',
  });
  try {
    const data = await bookingSupplierPayoutService.registerBeneficiary({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      beneficiaryUserId,
      accountNumber: req.body.account_number,
      bankCode: req.body.bank_code,
      idempotencyKey: key,
    });
    return res.status(201).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const decideBookingPayoutBeneficiary = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.beneficiaryId)
    || !validKey(key)
    || typeof req.body.approve !== 'boolean'
    || typeof req.body.reason !== 'string'
    || req.body.reason.trim().length < 10
    || req.body.reason.trim().length > 1_000
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_PAYOUT_BENEFICIARY_DECISION_INVALID',
  });
  try {
    const data = await bookingSupplierPayoutService.decideBeneficiary({
      beneficiaryId: req.params.beneficiaryId,
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

export const listBookingPayoutBeneficiaries = async (
  req: TenantRequest,
  res: Response,
) => {
  try {
    const data = await bookingSupplierPayoutService.listBeneficiaries(
      req.tenant!.id,
      req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const proposeBookingPayoutChangeRule = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!validKey(key)
    || !Number.isSafeInteger(req.body.version)
    || req.body.version <= 0
    || !Number.isSafeInteger(req.body.change_window_hours)
    || req.body.change_window_hours < 1
    || req.body.change_window_hours > 168
    || typeof req.body.effective_from !== 'string'
    || Number.isNaN(Date.parse(req.body.effective_from))
    || typeof req.body.change_reason !== 'string'
    || req.body.change_reason.trim().length < 10
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_PAYOUT_CHANGE_RULE_INVALID',
  });
  try {
    const data = await bookingSupplierPayoutService.proposeChangeRule({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      version: req.body.version,
      changeWindowHours: req.body.change_window_hours,
      effectiveFrom: req.body.effective_from,
      changeReason: req.body.change_reason.trim(),
      idempotencyKey: key,
    });
    return res.status(201).json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const decideBookingPayoutChangeRule = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.ruleId)
    || !validKey(key)
    || typeof req.body.approve !== 'boolean'
    || typeof req.body.reason !== 'string'
    || req.body.reason.trim().length < 10
    || req.body.reason.trim().length > 1_000
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_PAYOUT_CHANGE_RULE_DECISION_INVALID',
  });
  try {
    const data = await bookingSupplierPayoutService.decideChangeRule({
      ruleId: req.params.ruleId,
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

export const createBookingSupplierPayout = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.releaseId)
    || !validKey(key)
    || typeof req.body.beneficiary_id !== 'string'
    || !UUID.test(req.body.beneficiary_id)
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_SUPPLIER_PAYOUT_INVALID',
  });
  const correlationId = correlationOf(req);
  try {
    const data = await bookingSupplierPayoutService.createAndSubmit({
      settlementReleaseId: req.params.releaseId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      beneficiaryId: req.body.beneficiary_id,
      idempotencyKey: key,
      correlationId,
    });
    return res.status(201).json({
      success: true,
      data,
      correlation_id: correlationId,
    });
  } catch (error) {
    return failure(res, error);
  }
};

export const getBookingSupplierPayout = async (
  req: TenantRequest,
  res: Response,
) => {
  if (!UUID.test(req.params.payoutId)) {
    return res.status(400).json({
      success: false,
      error: 'BOOKING_SUPPLIER_PAYOUT_INVALID',
    });
  }
  try {
    const data = await bookingSupplierPayoutService.read(
      req.params.payoutId,
      req.tenant!.id,
      req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const syncBookingSupplierPayout = async (
  req: TenantRequest,
  res: Response,
) => {
  if (!UUID.test(req.params.payoutId)) {
    return res.status(400).json({
      success: false,
      error: 'BOOKING_SUPPLIER_PAYOUT_INVALID',
    });
  }
  try {
    const data = await bookingSupplierPayoutService.sync(
      req.params.payoutId,
      req.tenant!.id,
      req.user!.id,
    );
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};

export const cancelBookingSupplierPayout = async (
  req: TenantRequest,
  res: Response,
) => {
  const key = keyOf(req);
  if (!UUID.test(req.params.payoutId)
    || !validKey(key)
    || typeof req.body.reason !== 'string'
    || req.body.reason.trim().length < 10
    || req.body.reason.trim().length > 500
  ) return res.status(400).json({
    success: false,
    error: 'BOOKING_SUPPLIER_PAYOUT_INVALID',
  });
  try {
    const data = await bookingSupplierPayoutService.cancel({
      payoutId: req.params.payoutId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      reason: req.body.reason.trim(),
      idempotencyKey: key,
    });
    return res.json({ success: true, data });
  } catch (error) {
    return failure(res, error);
  }
};
