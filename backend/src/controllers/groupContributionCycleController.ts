import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { groupContributionCycleService } from '../services/groupContributionCycleService.js';

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

const openSchema = Joi.object({
  productId: Joi.string().uuid().required(),
  periodKey: Joi.string().pattern(/^[0-9]{4}(-[0-9]{2}){0,2}$/).required(),
  periodStart: Joi.date().iso().required(),
  periodEnd: Joi.date().iso().min(Joi.ref('periodStart')).required(),
  // A cycle must not fall due before the period it bills for has begun.
  dueDate: Joi.date().iso().min(Joi.ref('periodStart')).required(),
  timezone: Joi.string().min(3).max(64).required(),
});

// An adjustment must state its kind, a signed delta, and why. The engine records
// the actor and preserves the original amount, so the schema refuses one that
// arrives without a warrant (clause 4).
const adjustSchema = Joi.object({
  adjustmentKind: Joi.string()
    .valid('waiver', 'reduction', 'correction', 'write_off').required(),
  deltaMinor: Joi.number().integer().invalid(0)
    .min(-100_000_000_000).max(100_000_000_000).required(),
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
  reason: Joi.string().trim().min(1).max(1000).required(),
  evidence: Joi.object().unknown(true).default({}),
});

const transitionSchema = Joi.object({
  toState: Joi.string().valid('grace', 'closing').required(),
});

const closeSchema = Joi.object({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
  acknowledgeExceptions: Joi.boolean().default(false),
});

const cancelSchema = Joi.object({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
  reason: Joi.string().trim().min(1).max(1000).required(),
});

// Every state refusal the cycle engine raises is a conflict with the cycle's
// current state, not a server fault. Listing the tokens explicitly keeps a new
// engine error from silently surfacing as a 500 and reading as a bug.
const CONFLICT_TOKENS = [
  'CONFLICT', 'MISMATCH', 'IMMUTABLE', 'CHANGED', 'EXCEEDS', 'REQUIRED',
  'EXCEPTIONS', 'UNRECONCILED', 'HAS_COLLECTIONS', 'ALREADY',
  'NOT_EFFECTIVE', 'NOT_ACTIVE', 'NOT_BILLING', 'NOT_CLOSING', 'NOT_PAYABLE',
  'NOT_BILLABLE', 'NO_ACTIVE_MEMBERS', 'CYCLE_OPEN', 'NOT_OPEN',
  'PERIOD_CLOSED', 'PERIOD_MISSING',
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
    : error.statusCode === 400 ? error.message : 'Group contribution cycle command failed.',
});

const validate = (schema: Joi.ObjectSchema, value: unknown) => {
  const result = schema.validate(value, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};

export const groupContributionCycleController = {
  async openCycle(req: TenantRequest, res: Response) {
    try {
      const value = validate(openSchema, req.body);
      const result = await groupContributionCycleService.openCycle(context(req), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async adjustObligation(req: TenantRequest, res: Response) {
    try {
      const obligationId = pathUuid(
        req.params.obligationId, 'GROUP_CONTRIBUTION_OBLIGATION_ID_INVALID',
      );
      const value = validate(adjustSchema, req.body);
      const result = await groupContributionCycleService.adjustObligation(
        context(req), obligationId, { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async transitionCycle(req: TenantRequest, res: Response) {
    try {
      const cycleId = pathUuid(req.params.cycleId, 'GROUP_CONTRIBUTION_CYCLE_ID_INVALID');
      const value = validate(transitionSchema, req.body);
      const result = await groupContributionCycleService.transitionCycle(
        context(req), cycleId, { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async closeCycle(req: TenantRequest, res: Response) {
    try {
      const cycleId = pathUuid(req.params.cycleId, 'GROUP_CONTRIBUTION_CYCLE_ID_INVALID');
      const value = validate(closeSchema, req.body);
      const result = await groupContributionCycleService.closeCycle(
        context(req), cycleId, { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async cancelCycle(req: TenantRequest, res: Response) {
    try {
      const cycleId = pathUuid(req.params.cycleId, 'GROUP_CONTRIBUTION_CYCLE_ID_INVALID');
      const value = validate(cancelSchema, req.body);
      const result = await groupContributionCycleService.cancelCycle(
        context(req), cycleId, { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async listCycles(req: TenantRequest, res: Response) {
    try {
      const productId = req.query.productId
        ? pathUuid(String(req.query.productId), 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID')
        : null;
      const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
      const result = await groupContributionCycleService.listCycles(
        context(req), productId, limit,
      );
      if (!result) return res.status(404).json({ error: 'Group contribution cycles not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async getCycle(req: TenantRequest, res: Response) {
    try {
      const cycleId = pathUuid(req.params.cycleId, 'GROUP_CONTRIBUTION_CYCLE_ID_INVALID');
      const result = await groupContributionCycleService.getCycle(context(req), cycleId);
      if (!result) return res.status(404).json({ error: 'Group contribution cycle not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
};
