import { Response } from 'express';
import Joi from 'joi';
import {
  BeginDisbursementCommand,
  DecideConditionCommand,
  DecideDestinationCommand,
  InitializeConditionsCommand,
  LoanDisbursementService,
  LoanDisbursementValidationError,
  ProposeDestinationCommand,
  SubmitConditionEvidenceCommand,
  loanDisbursementService,
} from '../domains/financial/loanDisbursementService.js';
import { TenantRequest } from '../middleware/tenant.js';

const idempotency = Joi.string().min(8).max(160).required();
const initializeSchema = Joi.object({ idempotencyKey: idempotency });
const evidenceSchema = Joi.object({
  evidenceReferences: Joi.array().items(Joi.string().min(1).max(120)).min(1).max(20).unique().required(),
  idempotencyKey: idempotency,
});
const conditionDecisionSchema = Joi.object({
  decision: Joi.string().valid('satisfy', 'reject').required(),
  reason: Joi.string().trim().min(12).max(1000).required(),
  idempotencyKey: idempotency,
});
const destinationSchema = Joi.object({
  accountNumber: Joi.string().pattern(/^\d{6,20}$/).required(),
  bankCode: Joi.string().pattern(/^[A-Za-z0-9._-]{2,40}$/).required(),
  idempotencyKey: idempotency,
});
const destinationDecisionSchema = Joi.object({
  decision: Joi.string().valid('verify', 'reject').required(),
  reason: Joi.string().trim().min(12).max(1000).required(),
  idempotencyKey: idempotency,
});
const beginSchema = Joi.object({
  destinationId: Joi.string().uuid().required(),
  correlationId: Joi.string().uuid().required(),
  idempotencyKey: idempotency,
});

const invalid = (res: Response, details: string[]) => res.status(400).json({
  success: false, error: 'INVALID_LOAN_DISBURSEMENT_COMMAND', details,
});

export class LoanDisbursementController {
  constructor(private readonly service: LoanDisbursementService = loanDisbursementService) {}

  initializeConditions = async (req: TenantRequest, res: Response) => {
    const value = this.validate(initializeSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 201, () => this.service.initializeConditions({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, offerId: req.params.offerId,
      scheduleId: req.params.scheduleId, idempotencyKey: value.idempotencyKey,
    } as InitializeConditionsCommand));
  };

  submitConditionEvidence = async (req: TenantRequest, res: Response) => {
    const value = this.validate(evidenceSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 201, () => this.service.submitConditionEvidence({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, conditionId: req.params.conditionId,
      evidenceReferences: value.evidenceReferences, idempotencyKey: value.idempotencyKey,
    } as SubmitConditionEvidenceCommand));
  };

  decideCondition = async (req: TenantRequest, res: Response) => {
    const value = this.validate(conditionDecisionSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 200, () => this.service.decideCondition({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, conditionId: req.params.conditionId,
      decision: value.decision, reason: value.reason, idempotencyKey: value.idempotencyKey,
    } as DecideConditionCommand));
  };

  proposeDestination = async (req: TenantRequest, res: Response) => {
    const value = this.validate(destinationSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 201, () => this.service.proposeDestination({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, accountNumber: value.accountNumber,
      bankCode: value.bankCode, idempotencyKey: value.idempotencyKey,
    } as ProposeDestinationCommand));
  };

  decideDestination = async (req: TenantRequest, res: Response) => {
    const value = this.validate(destinationDecisionSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 200, () => this.service.decideDestination({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, destinationId: req.params.destinationId,
      decision: value.decision, reason: value.reason, idempotencyKey: value.idempotencyKey,
    } as DecideDestinationCommand));
  };

  beginDisbursement = async (req: TenantRequest, res: Response) => {
    const value = this.validate(beginSchema, req.body, res);
    if (!value) return;
    return this.execute(res, 202, () => this.service.beginDisbursement({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, destinationId: value.destinationId,
      correlationId: value.correlationId, idempotencyKey: value.idempotencyKey,
    } as BeginDisbursementCommand));
  };

  syncDisbursement = async (req: TenantRequest, res: Response) => this.execute(res, 200, () =>
    this.service.syncDisbursement({
      organizationId: req.tenant!.id, actorId: req.user!.id,
      applicationId: req.params.applicationId, disbursementId: req.params.disbursementId,
    }));

  private validate(schema: Joi.ObjectSchema, body: unknown, res: Response): any | null {
    const { error, value } = schema.validate(body, { abortEarly: false, stripUnknown: true });
    if (!error) return value;
    invalid(res, error.details.map((detail) => detail.message));
    return null;
  }

  private async execute(res: Response, successStatus: number, command: () => Promise<unknown>) {
    try {
      return res.status(successStatus).json(await command());
    } catch (error) {
      if (error instanceof LoanDisbursementValidationError) {
        return res.status(400).json({
          success: false, error: 'INVALID_LOAN_DISBURSEMENT_COMMAND', message: error.message,
        });
      }
      return res.status(409).json({
        success: false,
        error: 'LOAN_DISBURSEMENT_COMMAND_REJECTED',
        message: 'The loan disbursement command could not be completed in its current state.',
      });
    }
  }
}

export const loanDisbursementController = new LoanDisbursementController();
