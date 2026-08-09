import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import treasuryService from '../services/groupTreasuryDisbursementService.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('A valid Idempotency-Key header is required.'), {
      statusCode: 400,
    });
  }
  return value;
};

const context = (req: TenantRequest) => ({
  organizationId: req.tenant!.id,
  groupId: req.params.id,
  actorId: req.user!.id,
});

const pathUuid = (value: string, code: string) => {
  const { error } = Joi.string().uuid().required().validate(value);
  if (error) throw Object.assign(new Error(code), { statusCode: 400 });
  return value;
};

// Clause 1: a spend request names its budget, its authorising proposal, who
// receives the money, the amount, the purpose, and the evidence. Anything
// missing is refused before a reservation can be taken against it.
const requestSchema = Joi.object({
  budgetId: Joi.string().uuid().required(),
  proposalId: Joi.string().uuid().required(),
  beneficiaryKind: Joi.string().valid('member', 'group', 'project').required(),
  beneficiaryMemberId: Joi.string().uuid().allow(null),
  beneficiaryGroupId: Joi.string().uuid().allow(null),
  beneficiaryProjectId: Joi.string().uuid().allow(null),
  amountMinor: Joi.number().integer().min(1).max(100_000_000_000).required(),
  currency: Joi.string().pattern(/^[A-Z]{3}$/).required(),
  purpose: Joi.string().trim().min(8).max(2000).required(),
  evidenceUri: Joi.string().trim().min(3).max(500).required(),
  executeFrom: Joi.date().iso().required(),
  // A window that closes before it opens would make the request unexecutable.
  executeUntil: Joi.date().iso().greater(Joi.ref('executeFrom')).required(),
});

const reasonSchema = Joi.object({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
});

const listSchema = Joi.object({
  state: Joi.string().valid(
    'requested', 'approved', 'disbursing', 'executed',
    'rejected', 'cancelled', 'expired', 'failed', 'reversed',
  ),
  budgetId: Joi.string().uuid(),
});

// GT-06B: an external disbursement names a verified beneficiary in place of an
// on-platform member, group, or project. The beneficiary reference is the only
// destination the engine will pay, so nothing else about the destination is
// accepted here.
const externalRequestSchema = Joi.object({
  budgetId: Joi.string().uuid().required(),
  proposalId: Joi.string().uuid().required(),
  externalBeneficiaryId: Joi.string().uuid().required(),
  amountMinor: Joi.number().integer().min(1).max(100_000_000_000).required(),
  currency: Joi.string().valid('NGN').required(),
  purpose: Joi.string().trim().min(8).max(2000).required(),
  evidenceUri: Joi.string().trim().min(3).max(500).required(),
  executeFrom: Joi.date().iso().required(),
  executeUntil: Joi.date().iso().greater(Joi.ref('executeFrom')).required(),
});

// The registry verifies the account with the provider before it is held, so a
// registration carries the raw destination once and never again — reads return
// masks only. The account name is confirmed by the provider but supplied here so
// a mismatch can be surfaced at registration rather than at payout time.
const beneficiaryRegisterSchema = Joi.object({
  beneficiaryUserId: Joi.string().uuid().allow(null),
  accountNumber: Joi.string().pattern(/^\d{10}$/).required(),
  bankCode: Joi.string().pattern(/^\d{3,6}$/).required(),
  accountName: Joi.string().trim().min(2).max(200).required(),
  currency: Joi.string().valid('NGN').required(),
});

const beneficiaryApproveSchema = Joi.object({
  approvalReason: Joi.string().trim().min(10).max(1000).required(),
});

const beneficiaryListSchema = Joi.object({
  state: Joi.string().valid(
    'pending_approval', 'verified', 'retired', 'rejected', 'suspended',
  ),
});

// Every state refusal the treasury engine raises is a conflict with the current
// state of the disbursement or the group's funds, not a server fault. Listing
// the tokens explicitly keeps a new engine error from surfacing as a 500 and
// reading as a bug.
const CONFLICT_TOKENS = [
  'CONFLICT', 'MISMATCH', 'IMMUTABLE', 'CHANGED', 'EXCEEDS', 'EXCEEDED',
  'ALREADY', 'INSUFFICIENT', 'NOT_ACTIVE', 'NOT_APPROVED', 'NOT_PENDING',
  'NOT_VERIFIED', 'NOT_EXTERNAL',
  'NOT_EXECUTED', 'NOT_PERMITTED', 'CEILING', 'WINDOW', 'SELF_APPROVAL',
  'SELF_BENEFICIARY', 'IS_BENEFICIARY', 'IS_SOURCE', 'CANNOT_CHECK',
  'CANNOT_REQUEST', 'MISSING', 'REQUIRED',
];

const statusFor = (error: any) => {
  if (error.statusCode) return error.statusCode;
  const message = error.message ?? '';
  if (message.includes('NOT_FOUND')) return 404;
  if (message.includes('PERMISSION') || message.includes('NOT_ELIGIBLE')) return 403;
  if (CONFLICT_TOKENS.some((token) => message.includes(token))) return 409;
  if (message.includes('INVALID') || message.includes('UNSUPPORTED')) return 400;
  return 500;
};

const sendError = (res: Response, error: any) => res.status(statusFor(error)).json({
  error: /^GROUP_[A-Z_]+$/.test(error.message ?? '')
    ? error.message
    : error.statusCode === 400 ? error.message : 'Group treasury command failed.',
});

const validate = (schema: Joi.ObjectSchema, value: unknown) => {
  const result = schema.validate(value, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};

export const groupTreasuryController = {
  async getAvailable(req: TenantRequest, res: Response) {
    try {
      const availableMinor = await treasuryService.getAvailableMinor(context(req));
      return res.json({ success: true, data: { availableMinor } });
    } catch (error) { return sendError(res, error); }
  },

  async listBudgets(req: TenantRequest, res: Response) {
    try {
      const data = await treasuryService.listBudgets(context(req));
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async activateBudget(req: TenantRequest, res: Response) {
    try {
      const budgetId = pathUuid(req.params.budgetId, 'GROUP_TREASURY_BUDGET_ID_INVALID');
      const result = await treasuryService.activateBudget(
        context(req), budgetId, { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async requestDisbursement(req: TenantRequest, res: Response) {
    try {
      const value = validate(requestSchema, req.body);
      const result = await treasuryService.requestDisbursement(context(req), {
        ...value,
        executeFrom: new Date(value.executeFrom).toISOString(),
        executeUntil: new Date(value.executeUntil).toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async approveDisbursement(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const result = await treasuryService.approveDisbursement(
        context(req), disbursementId, { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async executeDisbursement(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const result = await treasuryService.executeDisbursement(
        context(req), disbursementId, { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async releaseReservation(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const value = validate(reasonSchema, req.body);
      const result = await treasuryService.releaseReservation(
        context(req), disbursementId,
        { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async reverseDisbursement(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const value = validate(reasonSchema, req.body);
      const result = await treasuryService.reverseDisbursement(
        context(req), disbursementId,
        { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async listDisbursements(req: TenantRequest, res: Response) {
    try {
      const filters = validate(listSchema, req.query);
      const data = await treasuryService.listDisbursements(context(req), filters);
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async getDisbursement(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const data = await treasuryService.getDisbursement(context(req), disbursementId);
      if (!data) {
        return res.status(404).json({ error: 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND' });
      }
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async listReservations(req: TenantRequest, res: Response) {
    try {
      const state = typeof req.query.state === 'string' ? req.query.state : undefined;
      const data = await treasuryService.listReservations(context(req), state);
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  // --- GT-06B external provider disbursements ------------------------------

  async registerBeneficiary(req: TenantRequest, res: Response) {
    try {
      const value = validate(beneficiaryRegisterSchema, req.body);
      const data = await treasuryService.registerBeneficiary(context(req), {
        ...value,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async approveBeneficiary(req: TenantRequest, res: Response) {
    try {
      const beneficiaryId = pathUuid(
        req.params.beneficiaryId, 'GROUP_TREASURY_BENEFICIARY_ID_INVALID',
      );
      const value = validate(beneficiaryApproveSchema, req.body);
      const data = await treasuryService.approveBeneficiary(
        context(req), beneficiaryId,
        { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async rejectBeneficiary(req: TenantRequest, res: Response) {
    try {
      const beneficiaryId = pathUuid(
        req.params.beneficiaryId, 'GROUP_TREASURY_BENEFICIARY_ID_INVALID',
      );
      const data = await treasuryService.rejectBeneficiary(
        context(req), beneficiaryId, { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async listBeneficiaries(req: TenantRequest, res: Response) {
    try {
      const { state } = validate(beneficiaryListSchema, req.query);
      const data = await treasuryService.listBeneficiaries(context(req), state);
      return res.json({ success: true, data });
    } catch (error) { return sendError(res, error); }
  },

  async requestExternalDisbursement(req: TenantRequest, res: Response) {
    try {
      const value = validate(externalRequestSchema, req.body);
      const result = await treasuryService.requestExternalDisbursement(context(req), {
        ...value,
        executeFrom: new Date(value.executeFrom).toISOString(),
        executeUntil: new Date(value.executeUntil).toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async beginExternalDisbursement(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const result = await treasuryService.beginExternalDisbursement(
        context(req), disbursementId, { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async syncExternalPayout(req: TenantRequest, res: Response) {
    try {
      const disbursementId = pathUuid(
        req.params.disbursementId, 'GROUP_TREASURY_DISBURSEMENT_ID_INVALID',
      );
      const result = await treasuryService.syncExternalPayout(context(req), disbursementId);
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
};
