import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { organizationInvitationService } from '../services/organizationInvitationService.js';

const role = Joi.string().valid(
  'owner', 'admin', 'finance_manager', 'program_manager',
  'farm_manager', 'auditor', 'member', 'viewer',
);
const permission = Joi.string().pattern(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/);

const createSchema = Joi.object({
  email: Joi.string().email().max(320).required(),
  role: role.required(),
  permissions: Joi.array().items(permission).unique().default([]),
  expiresAt: Joi.date().iso().greater('now').required(),
});
const acceptSchema = Joi.object({
  token: Joi.string().pattern(/^[A-Za-z0-9_-]{32,256}$/).required(),
});
const invitationIdSchema = Joi.string().uuid().required();

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('IDEMPOTENCY_KEY_REQUIRED'), { statusCode: 400 });
  }
  return value;
};

const knownError = /^(ORGANIZATION_|IDEMPOTENCY_)[A-Z_]+$/;
const fail = (res: Response, error: any) => {
  const code = knownError.test(error?.message)
    ? error.message
    : 'ORGANIZATION_INVITATION_COMMAND_FAILED';
  const status = error?.statusCode
    ?? (code.includes('NOT_FOUND') ? 404
      : code.includes('PERMISSION') || code.includes('REQUIRES_OWNER') ? 403
        : code.includes('INVALID') || code.includes('KEY_REQUIRED') ? 400
          : 409);
  return res.status(status).json({ success: false, error: code });
};

export const organizationInvitationController = {
  async create(req: TenantRequest, res: Response) {
    const { error, value } = createSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({
        success: false,
        error: 'VALIDATION_ERROR',
        details: error.details.map((item) => item.message),
      });
    }
    try {
      const data = await organizationInvitationService.create({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        email: value.email,
        role: value.role,
        permissions: value.permissions,
        expiresAt: new Date(value.expiresAt).toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      res.set('Cache-Control', 'no-store');
      return res.status(201).json({ success: true, data });
    } catch (commandError) {
      return fail(res, commandError);
    }
  },

  async accept(req: TenantRequest, res: Response) {
    const { error, value } = acceptSchema.validate(req.body, { stripUnknown: true });
    if (error) {
      return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    }
    try {
      const data = await organizationInvitationService.accept(req.user!.id, value.token);
      return res.json({ success: true, data });
    } catch (commandError) {
      return fail(res, commandError);
    }
  },

  async revoke(req: TenantRequest, res: Response) {
    const { error } = invitationIdSchema.validate(req.params.invitationId);
    if (error) {
      return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    }
    try {
      const data = await organizationInvitationService.revoke(
        req.tenant!.id,
        req.user!.id,
        req.params.invitationId,
      );
      return res.json({ success: true, data });
    } catch (commandError) {
      return fail(res, commandError);
    }
  },

  async list(req: TenantRequest, res: Response) {
    try {
      const data = await organizationInvitationService.list(req.tenant!.id);
      return res.json({ success: true, data });
    } catch (commandError) {
      return fail(res, commandError);
    }
  },
};
