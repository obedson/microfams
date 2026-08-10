import { randomUUID } from 'crypto';
import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { SavingsProductService, SavingsValidationError, savingsProductService } from '../domains/financial/savingsProductService.js';

const idempotencyKey = Joi.string().min(8).max(160).required();
const lifecycleSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
  idempotencyKey,
});
const createSchema = Joi.object({
  code: Joi.string().pattern(/^[A-Z0-9][A-Z0-9._-]{1,39}$/).required(),
  name: Joi.string().trim().min(2).max(160).required(),
  currency: Joi.string().pattern(/^[A-Z]{3}$/).required(),
  minimumContributionMinor: Joi.number().integer().min(1).required(),
  maximumContributionMinor: Joi.number().integer().min(1).required(),
  contributionFrequency: Joi.string().valid('manual', 'daily', 'weekly', 'monthly', 'quarterly').required(),
  defaultTargetMinor: Joi.number().integer().min(1),
  lockPeriodDays: Joi.number().integer().min(0).required(),
  gracePeriodDays: Joi.number().integer().min(0).required(),
  earlyWithdrawalRule: Joi.string().valid('blocked', 'allowed', 'forfeit_returns', 'fee').required(),
  earlyWithdrawalFeeMinor: Joi.number().integer().min(0).required(),
  returnMethod: Joi.string().valid('none', 'simple_interest').required(),
  annualRateBasisPoints: Joi.number().integer().min(0).max(100000).required(),
  dayCountConvention: Joi.string().valid('actual_365', 'actual_360').required(),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: Joi.string().pattern(/^[a-f0-9]{64}$/).required(),
  eligibility: Joi.object().required(),
  idempotencyKey,
});
const enrolSchema = Joi.object({
  targetMinor: Joi.number().integer().min(1),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: Joi.string().pattern(/^[a-f0-9]{64}$/).required(),
  idempotencyKey,
});
const contributionSchema = Joi.object({
  amountMinor: Joi.number().integer().min(1).required(),
  idempotencyKey,
});
const standingOrderSchema = Joi.object({
  amountMinor: Joi.number().integer().min(1).required(),
  firstDueAt: Joi.string().isoDate().required(),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: Joi.string().pattern(/^[a-f0-9]{64}$/).required(),
  idempotencyKey,
});
const transitionSchema = Joi.object({ idempotencyKey });
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class SavingsController {
  constructor(private readonly service: SavingsProductService = savingsProductService) {}

  listProducts = async (req: TenantRequest, res: Response) => {
    try {
      const products = await this.service.listProducts(req.tenant!.id, req.user!.id);
      return res.json({ products });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  listEnrolments = async (req: TenantRequest, res: Response) => {
    try {
      const enrolments = await this.service.listEnrolments(req.tenant!.id, req.user!.id);
      return res.json({ enrolments });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  createProduct = async (req: TenantRequest, res: Response) => {
    const { error, value } = createSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_PRODUCT', details: error.details.map((d) => d.message) });
    try {
      const result = await this.service.createProduct({ ...value, organizationId: req.tenant!.id, actorId: req.user!.id });
      return res.status(201).json(result);
    } catch (serviceError) {
      return this.respondError(serviceError, res);
    }
  };

  submitProduct = async (req: TenantRequest, res: Response) => {
    return this.lifecycle(req, res, 'submit');
  };

  approveProduct = async (req: TenantRequest, res: Response) => {
    return this.lifecycle(req, res, 'approve');
  };

  enrol = async (req: TenantRequest, res: Response) => {
    const { error, value } = enrolSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_ENROLMENT', details: error.details.map((d) => d.message) });
    try {
      const result = await this.service.enrol({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, productId: req.params.productId,
      });
      return res.status(201).json(result);
    } catch (serviceError) {
      return this.respondError(serviceError, res);
    }
  };

  contribute = async (req: TenantRequest, res: Response) => {
    const { error, value } = contributionSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_CONTRIBUTION', details: error.details.map((d) => d.message) });
    const supplied = req.headers['x-correlation-id'];
    const correlationId = typeof supplied === 'string' && UUID_PATTERN.test(supplied) ? supplied : randomUUID();
    try {
      const result = await this.service.contribute({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        enrolmentId: req.params.enrolmentId, correlationId,
      });
      return res.status(201).json({ contribution: result, correlationId });
    } catch (serviceError) {
      return this.respondError(serviceError, res);
    }
  };

  createStandingOrder = async (req: TenantRequest, res: Response) => {
    const { error, value } = standingOrderSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_STANDING_ORDER', details: error.details.map((d) => d.message) });
    try {
      const result = await this.service.createStandingOrder({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        enrolmentId: req.params.enrolmentId,
      });
      return res.status(201).json({ standingOrder: result });
    } catch (serviceError) {
      return this.respondError(serviceError, res);
    }
  };

  transitionStandingOrder = (action: 'pause' | 'resume' | 'cancel') =>
    async (req: TenantRequest, res: Response) => {
      const { error, value } = transitionSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
      if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_STANDING_ORDER', details: error.details.map((d) => d.message) });
      try {
        const result = await this.service.transitionStandingOrder({
          ...value, action, organizationId: req.tenant!.id, actorId: req.user!.id,
          standingOrderId: req.params.standingOrderId,
        });
        return res.json({ standingOrder: result });
      } catch (serviceError) {
        return this.respondError(serviceError, res);
      }
    };

  listContributions = async (req: TenantRequest, res: Response) => {
    try {
      const contributions = await this.service.listContributions(req.tenant!.id, req.user!.id, req.params.enrolmentId);
      return res.json({ contributions });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  listStandingOrders = async (req: TenantRequest, res: Response) => {
    try {
      const standingOrders = await this.service.listStandingOrders(req.tenant!.id, req.user!.id, req.params.enrolmentId);
      return res.json({ standingOrders });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  private async lifecycle(req: TenantRequest, res: Response, action: 'submit' | 'approve') {
    const { error, value } = lifecycleSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_COMMAND', details: error.details.map((d) => d.message) });
    try {
      const command = {
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, productId: req.params.productId,
      };
      const result = action === 'submit'
        ? await this.service.submitProduct(command)
        : await this.service.approveProduct(command);
      return res.json(result);
    } catch (serviceError) {
      return this.respondError(serviceError, res);
    }
  }

  private respondError(error: unknown, res: Response) {
    if (error instanceof SavingsValidationError) {
      return res.status(400).json({ success: false, error: 'INVALID_SAVINGS_COMMAND', message: error.message });
    }
    return res.status(409).json({
      success: false,
      error: 'SAVINGS_COMMAND_REJECTED',
      message: 'The savings command could not be completed in its current state.',
    });
  }
}

export const savingsController = new SavingsController();
