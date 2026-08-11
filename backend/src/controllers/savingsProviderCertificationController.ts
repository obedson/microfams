import { Response } from 'express';
import Joi from 'joi';
import {
  SavingsProviderCertificationError,
  SavingsProviderCertificationService,
  savingsProviderCertificationService,
} from '../domains/financial/savingsProviderCertificationService.js';
import { TenantRequest } from '../middleware/tenant.js';

const idempotencyKey = Joi.string().min(8).max(160).required();
const evidenceReference = Joi.string().trim().min(8).max(500).required();
const hash = Joi.string().pattern(/^[a-f0-9]{64}$/).required();
const createSchema = Joi.object({
  providerCode: Joi.string().pattern(/^[a-z][a-z0-9_.-]{1,63}$/).required(),
  providerLegalName: Joi.string().trim().min(2).max(160).required(),
  environment: Joi.string().valid('sandbox', 'live').required(),
  jurisdiction: Joi.string().pattern(/^[A-Z]{2}$/).required(),
  currency: Joi.string().pattern(/^[A-Z]{3}$/).required(),
  version: Joi.number().integer().min(1).required(),
  configurationFingerprint: hash,
  providerContractReference: evidenceReference,
  credentialsValidationReference: evidenceReference,
  webhookCertificationReference: evidenceReference,
  settlementAccountReference: evidenceReference,
  complianceNotesReference: evidenceReference,
  threatModelReference: evidenceReference,
  dataProtectionReviewReference: evidenceReference,
  supportRunbookReference: evidenceReference,
  reconciliationSignoffReference: evidenceReference,
  limitsDisclosuresReference: evidenceReference,
  operationalOwnerId: Joi.string().uuid().required(),
  validUntil: Joi.string().isoDate().required(),
  idempotencyKey,
});
const scenarioSchema = Joi.object({
  scenarioCode: Joi.string().valid(
    'contribution_success', 'contribution_duplicate', 'contribution_failure',
    'standing_order_retry', 'withdrawal_success', 'withdrawal_failure',
    'provider_callback_replay', 'reconciliation_zero_variance', 'servicing_after_disable',
  ).required(),
  attemptNumber: Joi.number().integer().min(1).required(),
  result: Joi.string().valid('passed', 'failed').required(),
  unexplainedVarianceMinor: Joi.number().integer().min(0).required(),
  evidenceReference,
  evidenceSha256: hash,
  startedAt: Joi.string().isoDate().required(),
  completedAt: Joi.string().isoDate().required(),
  idempotencyKey,
});
const transitionSchema = Joi.object({
  reason: Joi.string().trim().min(8).max(1000).required(),
  idempotencyKey,
});
const decisionSchema = transitionSchema.concat(Joi.object({ approve: Joi.boolean().required() }));
const readinessSchema = Joi.object({
  providerCode: Joi.string().pattern(/^[a-z][a-z0-9_.-]{1,63}$/).required(),
  environment: Joi.string().valid('sandbox', 'live').required(),
  jurisdiction: Joi.string().pattern(/^[A-Z]{2}$/).required(),
  currency: Joi.string().pattern(/^[A-Z]{3}$/).required(),
  configurationFingerprint: hash,
});

export class SavingsProviderCertificationController {
  constructor(private readonly service: SavingsProviderCertificationService = savingsProviderCertificationService) {}

  list = async (req: TenantRequest, res: Response) => {
    try {
      const certifications = await this.service.list(req.tenant!.id, req.user!.id);
      return res.json({ certifications });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  create = async (req: TenantRequest, res: Response) => {
    const value = this.validate(createSchema, req.body, res);
    if (!value) return;
    try {
      const certification = await this.service.create({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
      });
      return res.status(201).json({ certification });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  recordScenario = async (req: TenantRequest, res: Response) => {
    const value = this.validate(scenarioSchema, req.body, res);
    if (!value) return;
    try {
      const scenario = await this.service.recordScenario({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        certificationId: req.params.certificationId,
      });
      return res.status(201).json({ scenario });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  submit = async (req: TenantRequest, res: Response) => {
    const value = this.validate(transitionSchema, req.body, res);
    if (!value) return;
    try {
      const certification = await this.service.submit({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        certificationId: req.params.certificationId,
      });
      return res.json({ certification });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  decide = async (req: TenantRequest, res: Response) => {
    const value = this.validate(decisionSchema, req.body, res);
    if (!value) return;
    try {
      const certification = await this.service.decide({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
        certificationId: req.params.certificationId,
      });
      return res.json({ certification });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  readiness = async (req: TenantRequest, res: Response) => {
    const value = this.validate(readinessSchema, req.query, res);
    if (!value) return;
    try {
      const readiness = await this.service.readiness({
        ...value, organizationId: req.tenant!.id, actorId: req.user!.id,
      });
      return res.json({ readiness });
    } catch (error) {
      return this.respondError(error, res);
    }
  };

  private validate(schema: Joi.ObjectSchema, input: unknown, res: Response) {
    const { error, value } = schema.validate(input, { abortEarly: false, stripUnknown: true });
    if (!error) return value;
    res.status(400).json({
      success: false, error: 'INVALID_SAVINGS_PROVIDER_CERTIFICATION',
      details: error.details.map((detail) => detail.message),
    });
    return undefined;
  }

  private respondError(error: unknown, res: Response) {
    if (error instanceof SavingsProviderCertificationError) {
      return res.status(400).json({ success: false, error: error.code, message: error.message });
    }
    return res.status(409).json({
      success: false,
      error: 'SAVINGS_PROVIDER_CERTIFICATION_REJECTED',
      message: 'The provider certification command could not be completed in its current state.',
    });
  }
}

export const savingsProviderCertificationController = new SavingsProviderCertificationController();
