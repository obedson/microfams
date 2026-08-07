import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import {
  GROUP_PROPOSAL_TYPES,
  GROUP_VOTE_CHOICES,
} from '../domains/groups/proposalRules.js';
import { groupProposalService } from '../services/groupProposalService.js';
import { normalizeOfficeProposalPayload } from '../domains/groups/officeRules.js';
import { normalizeCommitteeProposalPayload } from '../domains/groups/committeeRules.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('A valid Idempotency-Key header is required.'), {
      statusCode: 400,
    });
  }
  return value;
};

const createSchema = Joi.object({
  proposalType: Joi.string().valid(...GROUP_PROPOSAL_TYPES).required(),
  publicSummary: Joi.string().trim().min(10).max(500).required(),
  privateEvidenceRefs: Joi.array().items(Joi.string().trim().min(1).max(500)).max(100).default([]),
  executionPayload: Joi.object().unknown(true).default({}),
  conflictUserIds: Joi.array().items(Joi.string().uuid()).unique().max(10_000).default([]),
  opensAt: Joi.date().iso().required(),
  closesAt: Joi.date().iso().greater(Joi.ref('opensAt')).required(),
});

const versionSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
});

const voteSchema = Joi.object({
  choice: Joi.string().valid(...GROUP_VOTE_CHOICES).required(),
});

const cancelSchema = versionSchema.keys({
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
});

const context = (req: TenantRequest) => ({
  organizationId: req.tenant!.id,
  groupId: req.params.id,
  actorId: req.user!.id,
});

const proposalId = (req: TenantRequest) => {
  const { error, value } = Joi.string().uuid().required().validate(req.params.proposalId);
  if (error) throw Object.assign(new Error('GROUP_PROPOSAL_ID_INVALID'), { statusCode: 400 });
  return value;
};

const statusFor = (error: any) => {
  if (error.statusCode) return error.statusCode;
  const message = error.message ?? '';
  if (message.includes('NOT_FOUND')) return 404;
  if (message.includes('NOT_ELIGIBLE') || message.includes('PERMISSION_DENIED')) return 403;
  if (message.includes('INVALID') || message.includes('REQUIRED')) return 400;
  if (
    message.includes('CONFLICT') || message.includes('NOT_OPEN')
    || message.includes('NOT_ACCEPTING') || message.includes('ALREADY_FINAL')
    || message.includes('STILL_OPEN') || message.includes('NO_ELIGIBLE')
  ) return 409;
  return 500;
};

const sendError = (res: Response, error: any) => res.status(statusFor(error)).json({
  error: /^GROUP_[A-Z_]+$/.test(error.message ?? '')
    ? error.message
    : error.statusCode === 400 ? error.message : 'Group proposal command failed.',
});

const validate = (schema: Joi.ObjectSchema, body: unknown) => {
  const result = schema.validate(body, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};

export const groupProposalController = {
  async create(req: TenantRequest, res: Response) {
    try {
      const value = validate(createSchema, req.body);
      const executionPayload = normalizeCommitteeProposalPayload(
        value.proposalType,
        normalizeOfficeProposalPayload(value.proposalType, value.executionPayload),
      );
      const result = await groupProposalService.create(context(req), {
        ...value, executionPayload,
        opensAt: value.opensAt.toISOString(),
        closesAt: value.closesAt.toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async open(req: TenantRequest, res: Response) {
    try {
      const value = validate(versionSchema, req.body);
      const result = await groupProposalService.open(context(req), proposalId(req), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async vote(req: TenantRequest, res: Response) {
    try {
      const value = validate(voteSchema, req.body);
      const result = await groupProposalService.vote(context(req), proposalId(req), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async close(req: TenantRequest, res: Response) {
    try {
      const value = validate(versionSchema, req.body);
      const result = await groupProposalService.close(context(req), proposalId(req), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async cancel(req: TenantRequest, res: Response) {
    try {
      const value = validate(cancelSchema, req.body);
      const result = await groupProposalService.cancel(context(req), proposalId(req), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async list(req: TenantRequest, res: Response) {
    try {
      const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
      const result = await groupProposalService.list(context(req), limit);
      if (!result) return res.status(404).json({ error: 'Group not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },

  async get(req: TenantRequest, res: Response) {
    try {
      const result = await groupProposalService.get(context(req), proposalId(req));
      if (!result) return res.status(404).json({ error: 'Group proposal not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
};
