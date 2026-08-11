import { Response } from 'express';
import Joi from 'joi';
import {
  GenerateLoanScheduleCommand,
  LoanScheduleService,
  LoanScheduleValidationError,
  loanScheduleService,
} from '../domains/financial/loanScheduleService.js';
import { TenantRequest } from '../middleware/tenant.js';

const generateSchema = Joi.object({
  idempotencyKey: Joi.string().min(8).max(160).required(),
});

export class LoanScheduleController {
  constructor(private readonly service: LoanScheduleService = loanScheduleService) {}

  generate = async (req: TenantRequest, res: Response) => {
    const { error, value } = generateSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) {
      return res.status(400).json({
        success: false,
        error: 'INVALID_LOAN_SCHEDULE_COMMAND',
        details: error.details.map((detail) => detail.message),
      });
    }
    try {
      const command: GenerateLoanScheduleCommand = {
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        applicationId: req.params.applicationId,
        offerId: req.params.offerId,
        idempotencyKey: value.idempotencyKey,
      };
      return res.status(201).json(await this.service.generate(command));
    } catch (caught) {
      if (caught instanceof LoanScheduleValidationError) {
        return res.status(400).json({
          success: false, error: 'INVALID_LOAN_SCHEDULE_COMMAND', message: caught.message,
        });
      }
      return res.status(409).json({
        success: false,
        error: 'LOAN_SCHEDULE_COMMAND_REJECTED',
        message: 'The contractual repayment schedule could not be generated in its current state.',
      });
    }
  };
}

export const loanScheduleController = new LoanScheduleController();
