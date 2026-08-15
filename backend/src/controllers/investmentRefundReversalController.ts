import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { InvestmentRefundReversalService, InvestmentRefundReversalValidationError, investmentRefundReversalService } from '../domains/financial/investmentRefundReversalService.js';

const proposalSchema = Joi.object({
  providerName: Joi.string().min(2).max(80).required(),
  providerEnvironment: Joi.string().valid('deterministic', 'sandbox', 'live').required(),
  providerReversalReference: Joi.string().min(4).max(200).required(),
  providerEventHash: Joi.string().hex().length(64).lowercase().required(),
  amountMinor: Joi.number().integer().positive().required(), currency: Joi.string().length(3).required(),
  occurredAt: Joi.date().iso().required(), reason: Joi.string().min(12).max(500).required(),
  evidenceReferences: Joi.array().min(1).required(), correlationId: Joi.string().uuid().required(),
  idempotencyKey: Joi.string().min(8).max(160).required(),
});
const decisionSchema = Joi.object({
  decision: Joi.string().valid('approve', 'reject').required(), reviewReason: Joi.string().min(12).max(500).required(),
  correlationId: Joi.string().uuid().required(), idempotencyKey: Joi.string().min(8).max(160).required(),
});

export class InvestmentRefundReversalController {
  constructor(private readonly service: InvestmentRefundReversalService = investmentRefundReversalService) {}
  propose = async (req: TenantRequest, res: Response) => {
    const { error, value } = proposalSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_INVESTMENT_REFUND_REVERSAL_COMMAND', details: error.details.map((detail) => detail.message) });
    try {
      return res.status(201).json(await this.service.propose({ ...value,
        occurredAt: new Date(value.occurredAt).toISOString(), organizationId: req.tenant!.id,
        actorId: req.user!.id, obligationId: req.params.obligationId,
      }));
    } catch (cause) { return this.failure(res, cause, 'INVALID_INVESTMENT_REFUND_REVERSAL_COMMAND', 'INVESTMENT_REFUND_REVERSAL_REJECTED'); }
  };
  decide = async (req: TenantRequest, res: Response) => {
    const { error, value } = decisionSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_INVESTMENT_REFUND_REVERSAL_DECISION', details: error.details.map((detail) => detail.message) });
    try {
      return res.status(200).json(await this.service.decide({ ...value, organizationId: req.tenant!.id,
        actorId: req.user!.id, reversalId: req.params.reversalId }));
    } catch (cause) { return this.failure(res, cause, 'INVALID_INVESTMENT_REFUND_REVERSAL_DECISION', 'INVESTMENT_REFUND_REVERSAL_DECISION_REJECTED'); }
  };
  private failure(res: Response, cause: unknown, validationCode: string, conflictCode: string) {
    if (cause instanceof InvestmentRefundReversalValidationError) return res.status(400).json({ success: false, error: validationCode, message: cause.message });
    return res.status(409).json({ success: false, error: conflictCode, message: 'The investment refund reversal could not be processed in its current state.' });
  }
}
export const investmentRefundReversalController = new InvestmentRefundReversalController();
