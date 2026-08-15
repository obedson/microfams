import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import emergencyService from '../services/groupTreasuryEmergencyService.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) throw Object.assign(new Error('A valid Idempotency-Key header is required.'), { statusCode: 400 });
  return value;
};
const context = (req: TenantRequest) => ({ organizationId: req.tenant!.id, groupId: req.params.id, actorId: req.user!.id });
const validate = (schema: Joi.ObjectSchema, value: unknown) => {
  const result = schema.validate(value, { abortEarly: false, stripUnknown: true });
  if (result.error) throw Object.assign(new Error(result.error.message), { statusCode: 400 });
  return result.value;
};
const statusFor = (error: any) => error.statusCode || (String(error.message).includes('NOT_FOUND') ? 404 : String(error.message).includes('PERMITTED') || String(error.message).includes('DISABLED') ? 403 : String(error.message).includes('INVALID') || String(error.message).includes('REQUIRED') ? 400 : 409);
const sendError = (res: Response, error: any) => res.status(statusFor(error)).json({ error: /^GROUP_[A-Z_]+$/.test(error.message ?? '') ? error.message : 'Group emergency command failed.' });
const policySchema = Joi.object({ enabled: Joi.boolean().required(), capMinor: Joi.number().integer().min(1).required(), ratificationHours: Joi.number().integer().min(1).max(720), noticeDeadlineMinutes: Joi.number().integer().min(1).max(10080) });
const requestSchema = Joi.object({ budgetId: Joi.string().uuid().required(), beneficiaryKind: Joi.string().valid('member', 'group', 'project').required(), beneficiaryMemberId: Joi.string().uuid().allow(null), beneficiaryGroupId: Joi.string().uuid().allow(null), beneficiaryProjectId: Joi.string().uuid().allow(null), amountMinor: Joi.number().integer().min(1).required(), currency: Joi.string().pattern(/^[A-Z]{3}$/).required(), purpose: Joi.string().trim().min(8).max(2000).required(), emergencyReason: Joi.string().trim().min(10).max(2000).required(), evidenceUri: Joi.string().trim().min(3).max(500).required() });
const pathId = (req: TenantRequest) => { const { error } = Joi.string().uuid().validate(req.params.emergencyId); if (error) throw Object.assign(new Error('GROUP_TREASURY_EMERGENCY_ID_INVALID'), { statusCode: 400 }); return req.params.emergencyId; };
export const groupTreasuryEmergencyController = {
  async getPolicy(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await emergencyService.getPolicy(context(req)) }); } catch (error) { return sendError(res, error); } },
  async configurePolicy(req: TenantRequest, res: Response) { try { const value = validate(policySchema, req.body); return res.json({ success: true, data: await emergencyService.configurePolicy(context(req), value) }); } catch (error) { return sendError(res, error); } },
  async list(req: TenantRequest, res: Response) { try { const state = typeof req.query.state === 'string' ? req.query.state : undefined; return res.json({ success: true, data: await emergencyService.list(context(req), state) }); } catch (error) { return sendError(res, error); } },
  async request(req: TenantRequest, res: Response) { try { const value = validate(requestSchema, req.body); return res.status(201).json({ success: true, data: await emergencyService.request(context(req), { ...value, idempotencyKey: idempotencyKey(req) }) }); } catch (error) { return sendError(res, error); } },
  async approve(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await emergencyService.approve(context(req), pathId(req), idempotencyKey(req)) }); } catch (error) { return sendError(res, error); } },
  async ratify(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await emergencyService.ratify(context(req), pathId(req), idempotencyKey(req)) }); } catch (error) { return sendError(res, error); } },
};
