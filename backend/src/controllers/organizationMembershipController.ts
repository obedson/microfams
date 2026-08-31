import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { organizationMembershipService } from '../services/organizationMembershipService.js';

const membershipIdSchema = Joi.string().uuid().required();
const role = Joi.string().valid(
  'admin', 'finance_manager', 'program_manager',
  'farm_manager', 'auditor', 'member', 'viewer',
);
const permission = Joi.string().pattern(
  /^[a-z][a-z0-9_]*(\.(\*|[a-z][a-z0-9_]*))+$/,
);
const accessSchema = Joi.object({
  role: role.required(),
  permissions: Joi.array().items(permission).max(64).unique().required(),
});

const knownError = /^ORGANIZATION_[A-Z_]+$/;
const fail = (res: Response, error: any) => {
  const code = knownError.test(error?.message)
    ? error.message
    : 'ORGANIZATION_MEMBERSHIP_ACCESS_FAILED';
  const status = code.includes('NOT_FOUND') ? 404
    : code.includes('PERMISSION') || code.includes('OWNERSHIP') ? 403
      : code.includes('INVALID') ? 400
        : 409;
  return res.status(status).json({ success: false, error: code });
};

export const organizationMembershipController = {
  async list(req: TenantRequest, res: Response) {
    try {
      const data = await organizationMembershipService.list(req.tenant!.id);
      return res.json({ success: true, data });
    } catch (error) {
      return fail(res, error);
    }
  },

  async updateAccess(req: TenantRequest, res: Response) {
    const membershipValidation = membershipIdSchema.validate(req.params.membershipId);
    const accessValidation = accessSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (membershipValidation.error || accessValidation.error) {
      return res.status(400).json({
        success: false,
        error: 'VALIDATION_ERROR',
        details: [
          ...(membershipValidation.error?.details ?? []),
          ...(accessValidation.error?.details ?? []),
        ].map((item) => item.message),
      });
    }

    try {
      const data = await organizationMembershipService.updateAccess({
        organizationId: req.tenant!.id,
        actorId: req.user!.id,
        membershipId: membershipValidation.value,
        role: accessValidation.value.role,
        permissions: accessValidation.value.permissions,
      });
      res.set('Cache-Control', 'no-store');
      return res.json({ success: true, data });
    } catch (error) {
      return fail(res, error);
    }
  },
};
