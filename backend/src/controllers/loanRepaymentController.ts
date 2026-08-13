import { Response } from 'express';
import Joi from 'joi';
import { LoanRepaymentService, LoanRepaymentValidationError, loanRepaymentService } from '../domains/financial/loanRepaymentService.js';
import { TenantRequest } from '../middleware/tenant.js';

const schema = Joi.object({
  amountMinor: Joi.number().integer().positive().max(Number.MAX_SAFE_INTEGER).required(),
  effectiveDate: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  correlationId: Joi.string().uuid().required(),
  idempotencyKey: Joi.string().min(8).max(160).required(),
});

export class LoanRepaymentController {
  constructor(private readonly service: LoanRepaymentService = loanRepaymentService) {}

  record = async (req: TenantRequest, res: Response) => {
    const { error, value } = schema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({
      success: false, error: 'INVALID_LOAN_REPAYMENT_COMMAND',
      details: error.details.map((detail) => detail.message),
    });
    try {
      return res.status(201).json(await this.service.record({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        applicationId: req.params.applicationId,
        contractId: req.params.contractId,
        amountMinor: value.amountMinor,
        effectiveDate: value.effectiveDate,
        correlationId: value.correlationId,
        idempotencyKey: value.idempotencyKey,
      }));
    } catch (caught) {
      if (caught instanceof LoanRepaymentValidationError) return res.status(400).json({
        success: false, error: 'INVALID_LOAN_REPAYMENT_COMMAND', message: caught.message,
      });
      return res.status(409).json({
        success: false, error: 'LOAN_REPAYMENT_COMMAND_REJECTED',
        message: 'The loan repayment could not be recorded in its current state.',
      });
    }
  };
}

export const loanRepaymentController = new LoanRepaymentController();
