import { Response } from 'express';
import Joi from 'joi';
import {
  CreateLoanApplicationCommand,
  DecideLoanAdverseReviewCommand,
  LoanApplicationCommand,
  LoanApplicationService,
  LoanApplicationValidationError,
  RequestLoanAdverseReviewCommand,
  WithdrawLoanApplicationCommand,
  loanApplicationService,
} from '../domains/financial/loanApplicationService.js';
import { TenantRequest } from '../middleware/tenant.js';

const idempotencyKey = Joi.string().min(8).max(160).required();
const hash = Joi.string().pattern(/^[a-f0-9]{64}$/).required();
const reference = Joi.string().pattern(/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$/);
const lifecycleSchema = Joi.object({ idempotencyKey });
const createSchema = Joi.object({
  productId: Joi.string().guid({ version: ['uuidv4', 'uuidv5'] }).required(),
  borrowerType: Joi.string().valid('individual', 'group', 'organization').required(),
  borrowerId: Joi.string().guid({ version: ['uuidv4', 'uuidv5'] }),
  purpose: Joi.string().pattern(/^[a-z][a-z0-9_]{1,39}$/).required(),
  requestedPrincipalMinor: Joi.number().integer().min(1).required(),
  requestedTenorDays: Joi.number().integer().min(1).required(),
  monthlyNetIncomeMinor: Joi.number().integer().min(1).required(),
  monthlyExistingDebtMinor: Joi.number().integer().min(0).required(),
  verifiedIncomeMonths: Joi.number().integer().min(0).required(),
  incomeEvidenceReferences: Joi.array().items(reference).max(20).unique().required(),
  identityEvidenceId: Joi.string().guid({ version: ['uuidv4', 'uuidv5'] }),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: hash,
  declarationVersion: Joi.string().trim().min(1).max(80).required(),
  declarationContentHash: hash,
  idempotencyKey,
});
const reviewRequestSchema = Joi.object({
  reason: Joi.string().trim().min(12).max(1000).required(),
  evidenceReferences: Joi.array().items(reference).max(20).unique().required(),
  idempotencyKey,
});
const reviewDecisionSchema = Joi.object({
  decision: Joi.string().valid('uphold', 'reopen').required(),
  reason: Joi.string().trim().min(12).max(1000).required(),
  idempotencyKey,
});
const withdrawalSchema = Joi.object({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,79}$/).required(),
  idempotencyKey,
});

export class LoanApplicationController {
  constructor(private readonly service: LoanApplicationService = loanApplicationService) {}

  list = async (req: TenantRequest, res: Response) => {
    try {
      return res.json({ applications: await this.service.listApplications(req.tenant!.id, req.user!.id) });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  create = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<CreateLoanApplicationCommand, 'organizationId' | 'actorId'>>(createSchema, req.body, res);
    if (!value) return;
    try {
      return res.status(201).json(await this.service.createApplication({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  submit = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Pick<LoanApplicationCommand, 'idempotencyKey'>>(lifecycleSchema, req.body, res);
    if (!value) return;
    try {
      return res.json(await this.service.submitApplication({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  requestAdverseReview = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Pick<RequestLoanAdverseReviewCommand, 'reason' | 'evidenceReferences' | 'idempotencyKey'>>(
      reviewRequestSchema, req.body, res,
    );
    if (!value) return;
    try {
      return res.json(await this.service.requestAdverseReview({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  decideAdverseReview = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Pick<DecideLoanAdverseReviewCommand, 'decision' | 'reason' | 'idempotencyKey'>>(
      reviewDecisionSchema, req.body, res,
    );
    if (!value) return;
    try {
      return res.json(await this.service.decideAdverseReview({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  withdraw = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Pick<WithdrawLoanApplicationCommand, 'reasonCode' | 'idempotencyKey'>>(
      withdrawalSchema, req.body, res,
    );
    if (!value) return;
    try {
      return res.json(await this.service.withdrawApplication({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, applicationId: req.params.applicationId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  private validate<T>(schema: Joi.ObjectSchema, body: unknown, res: Response): T | undefined {
    const { error, value } = schema.validate(body, { abortEarly: false, stripUnknown: true });
    if (!error) return value as T;
    res.status(400).json({
      success: false, error: 'INVALID_LOAN_APPLICATION_COMMAND', details: error.details.map((detail) => detail.message),
    });
    return undefined;
  }

  private respondError(error: unknown, res: Response) {
    if (error instanceof LoanApplicationValidationError) {
      return res.status(400).json({ success: false, error: 'INVALID_LOAN_APPLICATION_COMMAND', message: error.message });
    }
    return res.status(409).json({
      success: false,
      error: 'LOAN_APPLICATION_COMMAND_REJECTED',
      message: 'The loan application command could not be completed in its current state.',
    });
  }
}

export const loanApplicationController = new LoanApplicationController();
