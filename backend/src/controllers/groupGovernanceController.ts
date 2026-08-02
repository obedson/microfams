import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import {
  GroupConstitutionRuleError,
} from '../domains/groups/constitutionRules.js';
import { groupGovernanceService } from '../services/groupGovernanceService.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('A valid Idempotency-Key header is required.'), {
      statusCode: 400,
    });
  }
  return value;
};

const constitutionSchema = Joi.object({
  name: Joi.string().trim().min(3).max(160).required(),
  rules: Joi.object({
    minimumMembers: Joi.number().integer().min(1).max(10_000).required(),
    ordinaryQuorumBps: Joi.number().integer().min(1).max(10_000).required(),
    ordinaryApprovalBps: Joi.number().integer().min(1).max(10_000).required(),
    specialQuorumBps: Joi.number().integer().min(1).max(10_000).required(),
    specialApprovalBps: Joi.number().integer().min(1).max(10_000).required(),
    voteChangeAllowed: Joi.boolean().strict().required(),
  }).required(),
});

const appointmentSchema = Joi.object({
  memberId: Joi.string().uuid().required(),
  termEndsAt: Joi.date().iso().greater('now').optional(),
});

const activationSchema = Joi.object({
  expectedLifecycleVersion: Joi.number().integer().min(1).required(),
});

const executionSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
});

const delegationSchema = Joi.object({
  assignmentId: Joi.string().uuid().required(),
  delegateMemberId: Joi.string().uuid().required(),
  delegationEndsAt: Joi.date().iso().greater('now').required(),
});

const delegationEndSchema = Joi.object({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
});

const routeUuid = (value: string, code: string) => {
  const result = Joi.string().uuid().required().validate(value);
  if (result.error) throw Object.assign(new Error(code), { statusCode: 400 });
  return result.value;
};

const officeKey = (value: string) => {
  if (!/^[a-z][a-z0-9_]{1,47}$/.test(value)) throw Object.assign(
    new Error('GROUP_OFFICE_KEY_INVALID'), { statusCode: 400 },
  );
  return value;
};

const context = (req: TenantRequest) => ({
  organizationId: req.tenant!.id,
  groupId: req.params.id,
  actorId: req.user!.id,
});

const statusFor = (error: any) => {
  if (error.statusCode) return error.statusCode;
  const message = error.message ?? '';
  if (message.includes('PERMISSION_DENIED')) return 403;
  if (message.includes('GROUP_NOT_FOUND')) return 404;
  if (
    message.includes('CONFLICT') || message.includes('NOT_ACTIVE')
    || message.includes('CONSTITUTION_CHANGED') || message.includes('ACTIVE_GROUP_REQUIRED')
  ) return 409;
  if (
    message.includes('NOT_ALLOWED')
    || message.includes('REQUIRED')
    || message.includes('INCOMPLETE')
    || message.includes('STATE_INVALID') || message.includes('WINDOW_INVALID')
  ) return 409;
  if (message.includes('INVALID')) return 400;
  return 500;
};

const sendError = (res: Response, error: any) => {
  const known = error instanceof GroupConstitutionRuleError
    || /GROUP_[A-Z_]+/.test(error.message ?? '');
  return res.status(statusFor(error)).json({
    error: known ? error.message : 'Group governance command failed.',
  });
};

export const groupGovernanceController = {
  async adoptInitial(req: TenantRequest, res: Response) {
    const { error, value } = constitutionSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupGovernanceService.adoptInitialConstitution(
        context(req), { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async appointInitialOffice(req: TenantRequest, res: Response) {
    const { error, value } = appointmentSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error || !/^[a-z][a-z0-9_]{1,47}$/.test(req.params.officeKey)) {
      return res.status(400).json({ error: error?.message ?? 'Invalid office key.' });
    }
    try {
      const result = await groupGovernanceService.appointInitialOffice(
        context(req), {
          officeKey: req.params.officeKey,
          memberId: value.memberId,
          termEndsAt: value.termEndsAt?.toISOString(),
          idempotencyKey: idempotencyKey(req),
        },
      );
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async activate(req: TenantRequest, res: Response) {
    const { error, value } = activationSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupGovernanceService.activate(
        context(req), { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async getSetup(req: TenantRequest, res: Response) {
    try {
      const result = await groupGovernanceService.getSetup(context(req));
      if (!result) return res.status(404).json({ error: 'Group not found' });
      return res.json({ success: true, data: result });
    } catch (error) {
      return sendError(res, error);
    }
  },

  async executeOfficeProposal(req: TenantRequest, res: Response) {
    const { error, value } = executionSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupGovernanceService.executeOfficeProposal(
        context(req), routeUuid(req.params.proposalId, 'GROUP_PROPOSAL_ID_INVALID'),
        { ...value, idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async delegateOffice(req: TenantRequest, res: Response) {
    const { error, value } = delegationSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupGovernanceService.delegateOffice(context(req), {
        officeKey: officeKey(req.params.officeKey),
        assignmentId: value.assignmentId,
        delegateMemberId: value.delegateMemberId,
        delegationEndsAt: value.delegationEndsAt.toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async endDelegation(req: TenantRequest, res: Response) {
    const { error, value } = delegationEndSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupGovernanceService.endDelegation(context(req), {
        officeKey: officeKey(req.params.officeKey),
        delegationId: routeUuid(
          req.params.assignmentId, 'GROUP_OFFICE_ASSIGNMENT_ID_INVALID',
        ),
        reasonCode: value.reasonCode,
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async serviceExpired(req: TenantRequest, res: Response) {
    try {
      const result = await groupGovernanceService.serviceExpiredOffices(
        context(req), { idempotencyKey: idempotencyKey(req) },
      );
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async getOfficeLifecycle(req: TenantRequest, res: Response) {
    try {
      const result = await groupGovernanceService.getOfficeLifecycle(context(req));
      if (!result) return res.status(404).json({ error: 'Group not found' });
      return res.json({ success: true, data: result });
    } catch (error) {
      return sendError(res, error);
    }
  },
};
