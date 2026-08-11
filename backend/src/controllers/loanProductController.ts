import { Response } from 'express';
import Joi from 'joi';
import {
  CreateLoanProductCommand,
  LoanProductLifecycleCommand,
  LoanProductService,
  LoanProductValidationError,
  ReviseLoanProductCommand,
  loanProductService,
} from '../domains/financial/loanProductService.js';
import { TenantRequest } from '../middleware/tenant.js';

const idempotencyKey = Joi.string().min(8).max(160).required();
const ruleCode = Joi.string().pattern(/^[a-z][a-z0-9_]{1,39}$/);
const productFacts = {
  lenderType: Joi.string().valid('organization', 'licensed_provider', 'partner').required(),
  lenderName: Joi.string().trim().min(2).max(160).required(),
  providerCode: Joi.string().pattern(/^[A-Z0-9][A-Z0-9._-]{1,39}$/),
  eligibleBorrowerTypes: Joi.array().items(Joi.string().valid('individual', 'group', 'organization')).min(1).unique().required(),
  purposes: Joi.array().items(ruleCode).min(1).unique().required(),
  minimumPrincipalMinor: Joi.number().integer().min(1).required(),
  maximumPrincipalMinor: Joi.number().integer().min(1).required(),
  minimumTenorDays: Joi.number().integer().min(1).required(),
  maximumTenorDays: Joi.number().integer().min(1).required(),
  repaymentFrequency: Joi.string().valid('weekly', 'fortnightly', 'monthly', 'quarterly', 'bullet').required(),
  interestMethod: Joi.string().valid('reducing_balance', 'flat', 'simple', 'zero_interest').required(),
  nominalAnnualRateBasisPoints: Joi.number().integer().min(0).max(100000).required(),
  aprBasisPoints: Joi.number().integer().min(0).max(100000).required(),
  effectiveAnnualCostBasisPoints: Joi.number().integer().min(0).max(100000).required(),
  fees: Joi.array().items(Joi.object({
    code: ruleCode.required(), label: Joi.string().trim().min(2).max(120).required(),
    calculation: Joi.string().valid('fixed', 'percentage').required(),
    amountMinor: Joi.number().integer().min(1), rateBasisPoints: Joi.number().integer().min(1).max(100000),
    timing: Joi.string().valid('application', 'disbursement', 'repayment', 'delinquency').required(),
    capitalized: Joi.boolean().required(),
  })).unique('code').required(),
  gracePeriodDays: Joi.number().integer().min(0).required(),
  collateralRules: Joi.object().required(),
  guaranteeRules: Joi.object().required(),
  affordabilityRules: Joi.object().required(),
  delinquencyStages: Joi.array().items(Joi.object({
    code: ruleCode.required(), label: Joi.string().trim().min(2).max(120).required(),
    startsAfterDays: Joi.number().integer().min(0).required(),
    classification: Joi.string().valid('late', 'delinquent', 'defaulted').required(),
  })).min(1).unique('code').required(),
  restructuringPolicy: Joi.object().required(),
  writeOffPolicy: Joi.object().required(),
  repaymentAllocationOrder: Joi.array().items(Joi.string().valid(
    'statutory_charges', 'collection_costs', 'penalties', 'accrued_interest', 'principal',
  )).length(5).unique().required(),
  penaltyCompoundingAllowed: Joi.boolean().required(),
  penaltyCompoundingLegalBasis: Joi.string().trim().min(12).max(500),
  disclosureVersion: Joi.string().trim().min(1).max(80).required(),
  disclosureContentHash: Joi.string().pattern(/^[a-f0-9]{64}$/).required(),
};

const createSchema = Joi.object({
  code: Joi.string().pattern(/^[A-Z0-9][A-Z0-9._-]{1,39}$/).required(),
  name: Joi.string().trim().min(2).max(160).required(),
  currency: Joi.string().pattern(/^[A-Z]{3}$/).required(),
  ...productFacts,
  idempotencyKey,
});
const revisionSchema = Joi.object({ expectedCurrentVersion: Joi.number().integer().min(1).required(), ...productFacts, idempotencyKey });
const lifecycleSchema = Joi.object({ version: Joi.number().integer().min(1).required(), idempotencyKey });

export class LoanProductController {
  constructor(private readonly service: LoanProductService = loanProductService) {}

  listActive = async (req: TenantRequest, res: Response) => {
    try {
      return res.json({ products: await this.service.listActiveProducts(req.tenant!.id, req.user!.id) });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  listGoverned = async (req: TenantRequest, res: Response) => {
    try {
      return res.json({ products: await this.service.listGovernedProducts(req.tenant!.id, req.user!.id) });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  create = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<CreateLoanProductCommand, 'organizationId' | 'actorId'>>(createSchema, req.body, res);
    if (!value) return;
    try {
      return res.status(201).json(await this.service.createProduct({ ...value, organizationId: req.tenant!.id, actorId: req.user!.id }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  revise = async (req: TenantRequest, res: Response) => {
    const value = this.validate<Omit<ReviseLoanProductCommand, 'organizationId' | 'actorId' | 'productId'>>(revisionSchema, req.body, res);
    if (!value) return;
    try {
      return res.status(201).json(await this.service.reviseProduct({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id, productId: req.params.productId,
      }));
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  submit = async (req: TenantRequest, res: Response) => this.lifecycle(req, res, 'submit');
  approve = async (req: TenantRequest, res: Response) => this.lifecycle(req, res, 'approve');

  private async lifecycle(req: TenantRequest, res: Response, action: 'submit' | 'approve') {
    const value = this.validate<Pick<LoanProductLifecycleCommand, 'version' | 'idempotencyKey'>>(lifecycleSchema, req.body, res);
    if (!value) return;
    try {
      const command = { ...value, organizationId: req.tenant!.id, actorId: req.user!.id, productId: req.params.productId };
      const result = action === 'submit' ? await this.service.submitProduct(command) : await this.service.approveProduct(command);
      return res.json(result);
    } catch (error) {
      return this.respondError(error, res);
    }
  }

  private validate<T>(schema: Joi.ObjectSchema, body: unknown, res: Response): T | undefined {
    const { error, value } = schema.validate(body, { abortEarly: false, stripUnknown: true });
    if (!error) return value as T;
    res.status(400).json({ success: false, error: 'INVALID_LOAN_PRODUCT_COMMAND', details: error.details.map((detail) => detail.message) });
    return undefined;
  }

  private respondError(error: unknown, res: Response) {
    if (error instanceof LoanProductValidationError) {
      return res.status(400).json({ success: false, error: 'INVALID_LOAN_PRODUCT_COMMAND', message: error.message });
    }
    return res.status(409).json({
      success: false,
      error: 'LOAN_PRODUCT_COMMAND_REJECTED',
      message: 'The loan product command could not be completed in its current state.',
    });
  }
}

export const loanProductController = new LoanProductController();
