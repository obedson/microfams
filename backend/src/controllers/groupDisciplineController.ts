import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import {
  GROUP_DISCIPLINE_ACTIONS,
  GROUP_DISCIPLINE_APPEAL_OUTCOMES,
  validateDisciplineSchedule,
  validateEvidenceRefs,
} from '../domains/groups/disciplineRules.js';
import { groupDisciplineService } from '../services/groupDisciplineService.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('A valid Idempotency-Key header is required.'), { statusCode: 400 });
  }
  return value;
};

const evidence = Joi.array().items(Joi.string().trim().min(1).max(500)).max(100);
const createSchema = Joi.object({
  proposedAction: Joi.string().valid(...GROUP_DISCIPLINE_ACTIONS).required(),
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
  publicNotice: Joi.string().trim().min(20).max(1000).required(),
  privateEvidenceRefs: evidence.min(1).required(),
  responseDueAt: Joi.date().iso().required(),
  proposalClosesAt: Joi.date().iso().required(),
  appealWindowDays: Joi.number().integer().min(1).max(90).required(),
});
const executeSchema = Joi.object({ expectedMembershipVersion: Joi.number().integer().min(1).required() });
const appealSchema = Joi.object({
  grounds: Joi.string().trim().min(20).max(4000).required(),
  evidenceRefs: evidence.default([]),
});
const decisionSchema = Joi.object({
  outcome: Joi.string().valid(...GROUP_DISCIPLINE_APPEAL_OUTCOMES).required(),
  reasonCode: Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required(),
  decisionEvidenceRefs: evidence.min(1).required(),
});

const validate = (schema: Joi.ObjectSchema, body: unknown) => {
  const result = schema.validate(body, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};
const uuidParam = (req: TenantRequest, name: 'memberId' | 'caseId' | 'appealId') => {
  const { error, value } = Joi.string().uuid().required().validate(req.params[name]);
  if (error) throw Object.assign(new Error(`GROUP_DISCIPLINE_${name.toUpperCase()}_INVALID`), { statusCode: 400 });
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
  if (message.includes('NOT_FOUND')) return 404;
  if (message.includes('PERMISSION_DENIED') || message.includes('NOT_APPELLANT')
    || message.includes('REVIEWER_CONFLICT')) return 403;
  if (message.includes('INVALID') || message.includes('REQUIRED')) return 400;
  if (message.includes('CONFLICT') || message.includes('NOT_APPROVED')
    || message.includes('NOT_APPEALABLE') || message.includes('APPEAL_WINDOW_CLOSED')
    || message.includes('NOT_ACCEPTING') || message.includes('UNAVAILABLE')
    || message.includes('ALREADY')) return 409;
  return 500;
};
const sendError = (res: Response, error: any) => res.status(statusFor(error)).json({
  error: /^GROUP_[A-Z_]+$/.test(error.message ?? '')
    ? error.message
    : error.statusCode === 400 ? error.message : 'Group discipline command failed.',
});

export const groupDisciplineController = {
  async create(req: TenantRequest, res: Response) {
    try {
      const value = validate(createSchema, req.body);
      const schedule = validateDisciplineSchedule({ ...value, noticeIssuedAt: new Date() });
      const result = await groupDisciplineService.create(context(req), uuidParam(req, 'memberId'), {
        proposedAction: value.proposedAction,
        reasonCode: value.reasonCode,
        publicNotice: value.publicNotice,
        privateEvidenceRefs: validateEvidenceRefs(value.privateEvidenceRefs, true),
        responseDueAt: schedule.responseDueAt,
        proposalClosesAt: schedule.proposalClosesAt,
        appealWindowDays: schedule.appealWindowDays,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
  async execute(req: TenantRequest, res: Response) {
    try {
      const value = validate(executeSchema, req.body);
      const result = await groupDisciplineService.execute(context(req), uuidParam(req, 'caseId'), {
        ...value, idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
  async appeal(req: TenantRequest, res: Response) {
    try {
      const value = validate(appealSchema, req.body);
      const result = await groupDisciplineService.appeal(context(req), uuidParam(req, 'caseId'), {
        grounds: value.grounds,
        evidenceRefs: validateEvidenceRefs(value.evidenceRefs, false),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
  async decideAppeal(req: TenantRequest, res: Response) {
    try {
      const value = validate(decisionSchema, req.body);
      const result = await groupDisciplineService.decideAppeal(context(req), uuidParam(req, 'appealId'), {
        ...value,
        decisionEvidenceRefs: validateEvidenceRefs(value.decisionEvidenceRefs, true),
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
  async listForMember(req: TenantRequest, res: Response) {
    try {
      const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
      const result = await groupDisciplineService.listForMember(
        context(req), uuidParam(req, 'memberId'), limit,
      );
      if (!result) return res.status(404).json({ error: 'Group member discipline cases not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
  async get(req: TenantRequest, res: Response) {
    try {
      const result = await groupDisciplineService.get(context(req), uuidParam(req, 'caseId'));
      if (!result) return res.status(404).json({ error: 'Group discipline case not found' });
      return res.json({ success: true, data: result });
    } catch (error) { return sendError(res, error); }
  },
};
