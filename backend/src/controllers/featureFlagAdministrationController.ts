import { Response } from 'express';
import Joi from 'joi';
import {
  FeatureFlagAdministrationError,
  featureFlagAdministrationService,
} from '../domains/platform/featureFlagAdministrationService.js';
import { AuthRequest } from '../middleware/auth.js';

const environment = Joi.string().valid('all', 'development', 'test', 'staging', 'production');
const reason = Joi.string().trim().min(8).max(500);

const overrideSchema = Joi.object({
  scopeType: Joi.string().valid('global', 'jurisdiction', 'tenant', 'actor').required(),
  scopeId: Joi.string().trim().max(200).allow(null).optional(),
  environment: environment.required(),
  enabled: Joi.boolean().required(),
  config: Joi.object().unknown(true).default({}),
  reason: reason.required(),
  effectiveFrom: Joi.date().iso().optional(),
  effectiveUntil: Joi.date().iso().optional(),
});

const decisionSchema = Joi.object({
  decision: Joi.string().valid('approve', 'reject').required(),
  reason: reason.required(),
});

const emergencySchema = Joi.object({
  disabled: Joi.boolean().required(),
  reason: reason.required(),
  incidentReference: Joi.string().trim().min(3).max(120).required(),
});

const effectiveSchema = Joi.object({
  environment: environment.invalid('all').required(),
  tenantId: Joi.string().trim().max(200).optional(),
  jurisdiction: Joi.string().trim().max(100).optional(),
  actorId: Joi.string().uuid().optional(),
});

const auditSchema = Joi.object({
  featureKey: Joi.string().trim().max(160).optional(),
  limit: Joi.number().integer().min(1).max(200).default(100),
});

const validationFailure = (res: Response, error: Joi.ValidationError) => res.status(400).json({
  success: false,
  error: 'VALIDATION_ERROR',
  details: error.details.map((item) => item.message),
});

const commandFailure = (res: Response, error: unknown) => {
  if (error instanceof FeatureFlagAdministrationError) {
    return res.status(error.status).json({
      success: false,
      error: error.code,
      message: error.message,
    });
  }
  return res.status(503).json({
    success: false,
    error: 'FEATURE_FLAG_ADMINISTRATION_UNAVAILABLE',
  });
};

export const featureFlagAdministrationController = {
  listCatalog(_req: AuthRequest, res: Response) {
    return res.json({ success: true, data: featureFlagAdministrationService.listCatalog() });
  },

  async effectiveDecision(req: AuthRequest, res: Response) {
    const { error, value } = effectiveSchema.validate(req.query, { abortEarly: false, stripUnknown: true });
    if (error) return validationFailure(res, error);
    try {
      const data = await featureFlagAdministrationService.evaluate(req.params.key, value);
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async proposeOverride(req: AuthRequest, res: Response) {
    const { error, value } = overrideSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return validationFailure(res, error);
    try {
      const data = await featureFlagAdministrationService.proposeOverride({
        actorId: req.user!.id,
        featureKey: req.params.key,
        ...value,
        effectiveFrom: value.effectiveFrom?.toISOString(),
        effectiveUntil: value.effectiveUntil?.toISOString(),
      });
      return res.status(201).json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async decideOverride(req: AuthRequest, res: Response) {
    const { error, value } = decisionSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return validationFailure(res, error);
    try {
      const data = await featureFlagAdministrationService.decideOverride(
        req.user!.id,
        req.params.overrideId,
        value.decision,
        value.reason,
      );
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async setEmergencyStop(req: AuthRequest, res: Response) {
    const { error, value } = emergencySchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return validationFailure(res, error);
    try {
      const data = await featureFlagAdministrationService.setEmergencyStop({
        actorId: req.user!.id,
        featureKey: req.params.key,
        ...value,
      });
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async listAudit(req: AuthRequest, res: Response) {
    const { error, value } = auditSchema.validate(req.query, { abortEarly: false, stripUnknown: true });
    if (error) return validationFailure(res, error);
    try {
      const data = await featureFlagAdministrationService.listAudit(value.featureKey, value.limit);
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },
};
