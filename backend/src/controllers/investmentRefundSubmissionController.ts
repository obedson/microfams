import { Response } from 'express';
import Joi from 'joi';
import {
  InvestmentRefundSubmissionService,
  InvestmentRefundSubmissionValidationError,
  SubmitInvestmentRefundCommand,
  investmentRefundSubmissionService,
} from '../domains/financial/investmentRefundSubmissionService.js';
import { TenantRequest } from '../middleware/tenant.js';

const schema = Joi.object({
  correlationId: Joi.string().uuid().required(),
  idempotencyKey: Joi.string().min(8).max(160).required(),
});

export class InvestmentRefundSubmissionController {
  constructor(private readonly service: InvestmentRefundSubmissionService = investmentRefundSubmissionService) {}

  submit = async (req: TenantRequest, res: Response) => {
    const { error, value } = schema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({
      success: false,
      error: 'INVALID_INVESTMENT_REFUND_SUBMISSION_COMMAND',
      details: error.details.map((detail) => detail.message),
    });
    return this.execute(res, 202, () => this.service.submit({
      ...(value as Pick<SubmitInvestmentRefundCommand, 'correlationId' | 'idempotencyKey'>),
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      obligationId: req.params.obligationId,
    }));
  };

  recover = async (req: TenantRequest, res: Response) => this.execute(res, 200, () =>
    this.service.recover({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      obligationId: req.params.obligationId,
    }));

  private async execute(res: Response, successStatus: number, command: () => Promise<unknown>) {
    try {
      return res.status(successStatus).json(await command());
    } catch (cause) {
      if (cause instanceof InvestmentRefundSubmissionValidationError) {
        return res.status(400).json({
          success: false,
          error: 'INVALID_INVESTMENT_REFUND_COMMAND',
          message: cause.message,
        });
      }
      return res.status(409).json({
        success: false,
        error: 'INVESTMENT_REFUND_COMMAND_REJECTED',
        message: 'The refund command could not be completed in its current state.',
      });
    }
  }
}

export const investmentRefundSubmissionController = new InvestmentRefundSubmissionController();
