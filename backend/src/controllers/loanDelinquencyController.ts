import { Response } from 'express';
import Joi from 'joi';
import { LoanDelinquencyService, LoanDelinquencyValidationError, loanDelinquencyService } from '../domains/financial/loanDelinquencyService.js';
import { TenantRequest } from '../middleware/tenant.js';

const schema = Joi.object({
  assessedOn: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  correlationId: Joi.string().uuid().required(),
  idempotencyKey: Joi.string().min(8).max(160).required(),
});

export class LoanDelinquencyController {
  constructor(private readonly service: LoanDelinquencyService = loanDelinquencyService) {}

  assess = async (req: TenantRequest, res: Response) => {
    const { error, value } = schema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({
      success: false, error: 'INVALID_LOAN_DELINQUENCY_COMMAND',
      details: error.details.map((detail) => detail.message),
    });
    try {
      return res.status(201).json(await this.service.assess({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        applicationId: req.params.applicationId,
        contractId: req.params.contractId,
        assessedOn: value.assessedOn,
        correlationId: value.correlationId,
        idempotencyKey: value.idempotencyKey,
      }));
    } catch (caught) {
      if (caught instanceof LoanDelinquencyValidationError) return res.status(400).json({
        success: false, error: 'INVALID_LOAN_DELINQUENCY_COMMAND', message: caught.message,
      });
      return res.status(409).json({
        success: false, error: 'LOAN_DELINQUENCY_COMMAND_REJECTED',
        message: 'The loan delinquency assessment could not be recorded in its current state.',
      });
    }
  };
}

export const loanDelinquencyController = new LoanDelinquencyController();
