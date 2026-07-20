import { Response } from 'express';
import Joi from 'joi';
import {
  PlatformAdministrationError,
  platformAdministrationService,
} from '../domains/platform/platformAdministrationService.js';
import { AuthRequest } from '../middleware/auth.js';

const reasonCode = Joi.string().trim().uppercase().pattern(/^[A-Z][A-Z0-9_]{2,63}$/);

const grantSchema = Joi.object({
  userId: Joi.string().uuid().required(),
  reasonCode: reasonCode.required(),
  expiresAt: Joi.date().iso().greater('now').optional(),
});

const suspendSchema = Joi.object({
  reasonCode: reasonCode.required(),
  reasonNote: Joi.string().trim().max(1000).optional(),
});

const resumeSchema = Joi.object({
  reasonCode: reasonCode.required(),
});

const revokeSchema = Joi.object({
  reasonCode: reasonCode.required(),
});

const validationFailure = (res: Response, error: Joi.ValidationError) => res.status(400).json({
  success: false,
  error: 'VALIDATION_ERROR',
  details: error.details.map((item) => item.message),
});

const commandFailure = (res: Response, error: unknown) => {
  if (error instanceof PlatformAdministrationError) {
    return res.status(error.status).json({
      success: false,
      error: error.code,
      message: error.message,
    });
  }
  return res.status(503).json({
    success: false,
    error: 'PLATFORM_ADMINISTRATION_UNAVAILABLE',
  });
};

export const platformAdministrationController = {
  async list(req: AuthRequest, res: Response) {
    try {
      return res.json({ success: true, data: await platformAdministrationService.list() });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async grant(req: AuthRequest, res: Response) {
    const { error, value } = grantSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return validationFailure(res, error);

    try {
      const data = await platformAdministrationService.grant(
        req.user!.id,
        value.userId,
        value.reasonCode,
        value.expiresAt ? value.expiresAt.toISOString() : undefined,
      );
      return res.status(201).json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async revoke(req: AuthRequest, res: Response) {
    const { error, value } = revokeSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return validationFailure(res, error);

    try {
      const data = await platformAdministrationService.revoke(
        req.user!.id,
        req.params.userId,
        value.reasonCode,
      );
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async suspend(req: AuthRequest, res: Response) {
    const { error, value } = suspendSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return validationFailure(res, error);

    try {
      const data = await platformAdministrationService.suspend(
        req.user!.id,
        req.params.id,
        value.reasonCode,
        value.reasonNote,
      );
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },

  async resume(req: AuthRequest, res: Response) {
    const { error, value } = resumeSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return validationFailure(res, error);

    try {
      const data = await platformAdministrationService.resume(
        req.user!.id,
        req.params.id,
        value.reasonCode,
      );
      return res.json({ success: true, data });
    } catch (commandError) {
      return commandFailure(res, commandError);
    }
  },
};
