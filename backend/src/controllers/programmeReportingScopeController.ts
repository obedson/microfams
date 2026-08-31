import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { programmeReportingScopeService } from '../domains/institutional/programmeReportingScopeService.js';

const uuid = Joi.string().uuid();
const requestSchema = Joi.object({
  participatingOrganizationId: uuid.required(),
  purpose: Joi.string().trim().min(10).max(1000).required(),
  permittedMetrics: Joi.array().items(
    Joi.string().pattern(/^aggregate\.[a-z][a-z0-9_]*$/),
  ).min(1).max(32).unique().required(),
  disclosureVersion: Joi.string().pattern(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/).required(),
  requestEvidence: Joi.string().min(10).max(4000).required(),
  expiresAt: Joi.date().iso().greater('now').required(),
});
const decisionSchema = Joi.object({
  decision: Joi.string().valid('granted', 'rejected').required(),
  reason: Joi.string().trim().min(3).max(1000).required(),
  consentEvidence: Joi.when('decision', {
    is: 'granted',
    then: Joi.string().min(10).max(4000).required(),
    otherwise: Joi.forbidden(),
  }),
  effectiveAt: Joi.when('decision', {
    is: 'granted',
    then: Joi.date().iso().greater('now').required(),
    otherwise: Joi.forbidden(),
  }),
});
const revocationSchema = Joi.object({
  reason: Joi.string().trim().min(3).max(1000).required(),
});

const fail = (res: Response, error: any) => {
  const code = /^PROGRAMME_REPORTING_SCOPE_[A-Z_]+$/.test(error?.message)
    ? error.message : 'PROGRAMME_REPORTING_SCOPE_FAILED';
  const status = code.includes('NOT_FOUND') ? 404
    : code.includes('PERMISSION') ? 403
      : code.includes('INVALID') ? 400 : 409;
  return res.status(status).json({ success: false, error: code });
};

const validate = (schema: Joi.ObjectSchema, value: unknown, res: Response) => {
  const result = schema.validate(value, { abortEarly: false, stripUnknown: true });
  if (!result.error) return result.value;
  res.status(400).json({
    success: false,
    error: 'VALIDATION_ERROR',
    details: result.error.details.map((item) => item.message),
  });
  return null;
};

export const programmeReportingScopeController = {
  async list(req: TenantRequest, res: Response) {
    try {
      res.set('Cache-Control', 'no-store');
      return res.json({
        success: true,
        data: await programmeReportingScopeService.list(req.tenant!.id),
      });
    } catch (error) {
      return fail(res, error);
    }
  },

  async request(req: TenantRequest, res: Response) {
    const body = validate(requestSchema, req.body, res);
    const programmeId = uuid.validate(req.params.id);
    if (!body) return;
    if (programmeId.error) {
      return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    }
    try {
      const data = await programmeReportingScopeService.request({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        programmeId: programmeId.value,
        ...body,
        expiresAt: new Date(body.expiresAt).toISOString(),
      });
      return res.status(201).json({ success: true, data });
    } catch (error) {
      return fail(res, error);
    }
  },

  async decide(req: TenantRequest, res: Response) {
    const body = validate(decisionSchema, req.body, res);
    const scopeId = uuid.validate(req.params.scopeId);
    if (!body) return;
    if (scopeId.error) {
      return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    }
    try {
      const data = await programmeReportingScopeService.decide({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        scopeId: scopeId.value,
        ...body,
        ...(body.effectiveAt
          ? { effectiveAt: new Date(body.effectiveAt).toISOString() } : {}),
      });
      return res.json({ success: true, data });
    } catch (error) {
      return fail(res, error);
    }
  },

  async revoke(req: TenantRequest, res: Response) {
    const body = validate(revocationSchema, req.body, res);
    const scopeId = uuid.validate(req.params.scopeId);
    if (!body) return;
    if (scopeId.error) {
      return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    }
    try {
      const data = await programmeReportingScopeService.revoke({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        scopeId: scopeId.value,
        reason: body.reason,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return fail(res, error);
    }
  },
};
