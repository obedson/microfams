import { Response } from 'express';
import Joi from 'joi';
import {
  InvestmentRefundReconciliationService,
  InvestmentRefundReconciliationValidationError,
  investmentRefundReconciliationService,
} from '../domains/financial/investmentRefundReconciliationService.js';
import { TenantRequest } from '../middleware/tenant.js';

const providerItem = Joi.object({
  internalReference: Joi.string().pattern(/^investment-refund-[0-9a-f-]{36}$/i).required(),
  providerReference: Joi.string().max(200).optional(),
  status: Joi.string().valid('submitted', 'processing', 'succeeded', 'failed', 'cancelled').required(),
  amountMinor: Joi.number().integer().positive().required(),
  currency: Joi.string().length(3).required(),
  occurredAt: Joi.date().iso().required(),
});

const schema = Joi.object({
  providerName: Joi.string().min(2).max(80).required(),
  providerEnvironment: Joi.string().valid('deterministic', 'sandbox', 'live').required(),
  sourceHash: Joi.string().hex().length(64).lowercase().required(),
  idempotencyKey: Joi.string().min(8).max(160).required(),
  periodStart: Joi.date().iso().required(),
  periodEnd: Joi.date().iso().greater(Joi.ref('periodStart')).required(),
  providerItems: Joi.array().items(providerItem).max(5000).required(),
});

export class InvestmentRefundReconciliationController {
  constructor(private readonly service: InvestmentRefundReconciliationService = investmentRefundReconciliationService) {}

  run = async (req: TenantRequest, res: Response) => {
    const { error, value } = schema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({
      success: false,
      error: 'INVALID_INVESTMENT_REFUND_RECONCILIATION_COMMAND',
      details: error.details.map((detail) => detail.message),
    });
    try {
      const result = await this.service.run({
        ...value,
        periodStart: new Date(value.periodStart).toISOString(),
        periodEnd: new Date(value.periodEnd).toISOString(),
        providerItems: value.providerItems.map((item: any) => ({ ...item, occurredAt: new Date(item.occurredAt).toISOString() })),
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
      });
      return res.status(201).json(result);
    } catch (cause) {
      if (cause instanceof InvestmentRefundReconciliationValidationError) {
        return res.status(400).json({ success: false, error: 'INVALID_INVESTMENT_REFUND_RECONCILIATION_COMMAND', message: cause.message });
      }
      return res.status(409).json({
        success: false,
        error: 'INVESTMENT_REFUND_RECONCILIATION_REJECTED',
        message: 'The reconciliation run could not be recorded.',
      });
    }
  };
}

export const investmentRefundReconciliationController = new InvestmentRefundReconciliationController();
