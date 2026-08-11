import { Response } from 'express';
import Joi from 'joi';
import {
  AcceptLoanOfferCommand,
  DeclineLoanApplicationCommand,
  ExpireLoanOfferCommand,
  IssueLoanOfferCommand,
  LoanOfferService,
  LoanOfferValidationError,
  loanOfferService,
} from '../domains/financial/loanOfferService.js';
import { TenantRequest } from '../middleware/tenant.js';

const idempotencyKey = Joi.string().min(8).max(160).required();
const hash = Joi.string().pattern(/^[a-f0-9]{64}$/).required();
const code = Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,79}$/);
const reviewFields = {
  reasonCodes: Joi.array().items(code).min(1).max(20).unique().required(),
  reviewReason: Joi.string().trim().min(12).max(1000).required(),
  idempotencyKey,
};
const issueSchema = Joi.object({
  principalMinor: Joi.number().integer().min(1).required(),
  tenorDays: Joi.number().integer().min(1).required(),
  totalInterestMinor: Joi.number().integer().min(0).required(),
  totalFeesMinor: Joi.number().integer().min(0).required(),
  totalRepayableMinor: Joi.number().integer().min(1).required(),
  conditionCodes: Joi.array().items(code).max(20).unique().required(),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: hash,
  expiresAt: Joi.string().isoDate().required(),
  ...reviewFields,
});
const declineSchema = Joi.object(reviewFields);
const acceptSchema = Joi.object({
  expectedOfferHash: hash,
  acceptanceVersion: Joi.string().trim().min(1).max(80).required(),
  acceptanceContentHash: hash,
  idempotencyKey,
});
const expireSchema = Joi.object({ reasonCode: code.required(), idempotencyKey });

export class LoanOfferController {
  constructor(private readonly service: LoanOfferService = loanOfferService) {}

  issue = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<IssueLoanOfferCommand, 'organizationId' | 'actorId' | 'applicationId'>>(
      issueSchema, req.body, res,
    );
    if (!value) return;
    try {
      return res.status(201).json(await this.service.issue({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  decline = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<DeclineLoanApplicationCommand, 'organizationId' | 'actorId' | 'applicationId'>>(
      declineSchema, req.body, res,
    );
    if (!value) return;
    try {
      return res.json(await this.service.decline({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  accept = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<AcceptLoanOfferCommand,
      'organizationId' | 'actorId' | 'applicationId' | 'offerId'>>(acceptSchema, req.body, res);
    if (!value) return;
    try {
      return res.json(await this.service.accept({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        applicationId: req.params.applicationId, offerId: req.params.offerId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  expire = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<ExpireLoanOfferCommand,
      'organizationId' | 'actorId' | 'applicationId' | 'offerId'>>(expireSchema, req.body, res);
    if (!value) return;
    try {
      return res.json(await this.service.expire({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        applicationId: req.params.applicationId, offerId: req.params.offerId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  private validate<T>(schema: Joi.ObjectSchema, body: unknown, res: Response): T | undefined {
    const { error, value } = schema.validate(body, { abortEarly: false, stripUnknown: true });
    if (!error) return value as T;
    res.status(400).json({
      success: false, error: 'INVALID_LOAN_OFFER_COMMAND', details: error.details.map((detail) => detail.message),
    });
    return undefined;
  }

  private respondError(error: unknown, res: Response) {
    if (error instanceof LoanOfferValidationError) {
      return res.status(400).json({ success: false, error: 'INVALID_LOAN_OFFER_COMMAND', message: error.message });
    }
    return res.status(409).json({
      success: false,
      error: 'LOAN_OFFER_COMMAND_REJECTED',
      message: 'The loan offer command could not be completed in its current state.',
    });
  }
}

export const loanOfferController = new LoanOfferController();
