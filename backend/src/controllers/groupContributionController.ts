import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { groupContributionService } from '../services/groupContributionService.js';

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

const executionSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
});

const paymentSchema = Joi.object({
  amountMinor: Joi.number().integer().min(1).max(100_000_000_000).optional(),
});

const allocationSchema = Joi.object({
  memberId: Joi.string().uuid().required(),
  paymentId: Joi.string().uuid().required(),
});

const statusFor = (error: any) => {
  if (error.statusCode) return error.statusCode;
  const message = error.message ?? '';
  if (message.includes('NOT_FOUND')) return 404;
  if (message.includes('PERMISSION') || message.includes('NOT_ELIGIBLE')) return 403;
  if (message.includes('INVALID') || message.includes('UNSUPPORTED')) return 400;
  if (
    message.includes('CONFLICT') || message.includes('MISMATCH')
    || message.includes('UNVERIFIED') || message.includes('IMMUTABLE')
    || message.includes('NOT_EFFECTIVE') || message.includes('NOT_YET_EFFECTIVE')
    || message.includes('NOT_ACTIVE') || message.includes('REQUIRED')
    || message.includes('CHANGED')
  ) return 409;
  return 500;
};

const sendError = (res: Response, error: any) => res.status(statusFor(error)).json({
  error: /^GROUP_[A-Z_]+$/.test(error.message ?? '')
    ? error.message
    : error.statusCode === 400 ? error.message : 'Group contribution command failed.',
});

const validate = (schema: Joi.ObjectSchema, value: unknown) => {
  const result = schema.validate(value, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};

export const groupContributionController = {
  async executeRuleProposal(req: TenantRequest, res: Response) {
    try {
      const proposalId = pathUuid(req.params.proposalId, 'GROUP_PROPOSAL_ID_INVALID');
      const value = validate(executionSchema, req.body);
      const result = await groupContributionService.executeRuleProposal(
        context(req), proposalId, { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async initializePayment(req: TenantRequest, res: Response) {
    try {
      const productId = pathUuid(req.params.productId, 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID');
      const value = validate(paymentSchema, req.body);
      const result = await groupContributionService.initializePayment(context(req), productId, {
        ...value, email: req.user!.email, idempotencyKey: idempotencyKey(req),
      });
      return res.status(202).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async allocatePayment(req: TenantRequest, res: Response) {
    try {
      const productId = pathUuid(req.params.productId, 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID');
      const value = validate(allocationSchema, req.body);
      const result = await groupContributionService.allocatePayment(context(req), productId, {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async listProducts(req: TenantRequest, res: Response) {
    try {
      const result = await groupContributionService.listProducts(context(req));
      if (!result) return res.status(404).json({ error: 'Group contribution products not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async getProduct(req: TenantRequest, res: Response) {
    try {
      const productId = pathUuid(req.params.productId, 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID');
      const result = await groupContributionService.getProduct(context(req), productId);
      if (!result) return res.status(404).json({ error: 'Group contribution product not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async listAllocations(req: TenantRequest, res: Response) {
    try {
      const productId = pathUuid(req.params.productId, 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID');
      const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
      const result = await groupContributionService.listAllocations(context(req), productId, limit);
      if (!result) return res.status(404).json({ error: 'Group contribution product not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
};
