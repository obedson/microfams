import { Response } from 'express';
import Joi from 'joi';
import { TrustDomainError } from '../domains/trust/trustRules.js';
import { trustReviewService } from '../domains/trust/trustReviewService.js';
import { TenantRequest } from '../middleware/tenant.js';
import { TrustActorContext } from '../domains/trust/trustTypes.js';

const uuid = Joi.string().uuid({ version: ['uuidv4', 'uuidv5'] });
const reasonCode = Joi.string().trim().uppercase().pattern(/^[A-Z][A-Z0-9_]{2,63}$/);
const idempotencyKey = Joi.string().trim().min(8).max(160).required();

const appealSchema = Joi.object({
  caseId: uuid.required(),
  grounds: Joi.string().trim().min(10).max(4000).required(),
});

const suspensionSchema = Joi.object({
  caseId: uuid.required(),
  reasonCode: reasonCode.required(),
});

const resumeSchema = Joi.object({
  reasonCode: reasonCode.required(),
});

const openReviewSchema = Joi.object({
  organizationId: uuid.optional(),
  subjectType: Joi.string().valid('user', 'membership', 'organization').required(),
  subjectId: uuid.required(),
  reasonCode: reasonCode.required(),
  priority: Joi.string().valid('low', 'normal', 'high', 'urgent').default('normal'),
});

const assignReviewSchema = Joi.object({
  reviewerId: uuid.required(),
});

const conflictSchema = Joi.object({
  conflictType: Joi.string().trim().lowercase().pattern(/^[a-z][a-z0-9_]{2,63}$/).required(),
  note: Joi.string().trim().max(1000).optional(),
});

const decideReviewSchema = Joi.object({
  outcome: Joi.string().valid(
    'no_action',
    'warning',
    'suspend_membership',
    'suspend_organization',
    'suspend_user',
    'refer',
  ).required(),
  reasonCode: reasonCode.required(),
  rationale: Joi.string().trim().min(10).max(4000).required(),
});

const decideAppealSchema = Joi.object({
  outcome: Joi.string().valid('upheld', 'modified', 'overturned', 'dismissed').required(),
  reasonCode: reasonCode.required(),
  rationale: Joi.string().trim().min(10).max(4000).required(),
});

const organizationSuspensionSchema = Joi.object({
  caseId: uuid.required(),
  reasonCode: reasonCode.required(),
});

const queueSchema = Joi.object({
  organizationId: uuid.optional(),
  state: Joi.string().trim().lowercase().max(40).optional(),
  limit: Joi.number().integer().min(1).max(100).default(50),
});

const retentionDryRunSchema = Joi.object({
  organizationId: uuid.optional(),
  policyId: uuid.required(),
});

const validationFailure = (res: Response, error: Joi.ValidationError) => res.status(400).json({
  success: false,
  error: 'VALIDATION_ERROR',
  details: error.details.map((item) => item.message),
});

const parse = (schema: Joi.ObjectSchema, input: unknown, res: Response) => {
  const result = schema.validate(input, { abortEarly: false, stripUnknown: true });
  if (result.error) {
    validationFailure(res, result.error);
    return undefined;
  }
  return result.value;
};

const commandKey = (req: TenantRequest, res: Response): string | undefined => {
  const raw = req.headers['idempotency-key'];
  const result = idempotencyKey.validate(Array.isArray(raw) ? undefined : raw);
  if (result.error) {
    res.status(400).json({ success: false, error: 'IDEMPOTENCY_KEY_REQUIRED' });
    return undefined;
  }
  return result.value;
};

const actorContext = (req: TenantRequest, platformAdministrator = false): TrustActorContext => ({
  actorId: req.user!.id,
  ...(req.tenant ? { organizationId: req.tenant.id } : {}),
  ...(platformAdministrator ? { platformAdministrator: true } : {}),
  environment: (
    ['development', 'test', 'staging', 'production'].includes(process.env.NODE_ENV || '')
      ? process.env.NODE_ENV
      : 'development'
  ) as TrustActorContext['environment'],
});

const commandFailure = (res: Response, error: unknown) => {
  if (error instanceof TrustDomainError) {
    if (['TRUST_SCOPE_VIOLATION', 'TRUST_SUBJECT_NOT_FOUND'].includes(error.code)) {
      return res.status(404).json({
        success: false,
        error: 'TRUST_RESOURCE_NOT_FOUND',
        message: 'The requested trust resource was not found',
      });
    }
    return res.status(error.status).json({
      success: false,
      error: error.code,
      message: error.message,
    });
  }
  return res.status(503).json({ success: false, error: 'TRUST_SERVICE_UNAVAILABLE' });
};

export const trustController = {
  async getSelfStatus(req: TenantRequest, res: Response) {
    try {
      const data = await trustReviewService.getSubjectStatus(
        actorContext(req),
        'user',
        req.user!.id,
      );
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async listSelfDecisions(req: TenantRequest, res: Response) {
    try {
      const data = await trustReviewService.listDecisions(
        actorContext(req),
        'user',
        req.user!.id,
      );
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async fileSelfAppeal(req: TenantRequest, res: Response) {
    const value = parse(appealSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.fileAppeal(actorContext(req), {
        caseId: value.caseId,
        grounds: value.grounds,
        idempotencyKey: key,
      });
      return res.status(202).json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async suspendMembership(req: TenantRequest, res: Response) {
    const value = parse(suspensionSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.suspendMembership(actorContext(req), {
        membershipId: req.params.membershipId,
        caseId: value.caseId,
        reasonCode: value.reasonCode,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async resumeMembership(req: TenantRequest, res: Response) {
    const value = parse(resumeSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.resumeMembership(actorContext(req), {
        membershipId: req.params.membershipId,
        reasonCode: value.reasonCode,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async listReviews(req: TenantRequest, res: Response) {
    const value = parse(queueSchema, req.query, res);
    if (!value) return;
    try {
      const data = await trustReviewService.listReviewQueue(actorContext(req, true), value);
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async openReview(req: TenantRequest, res: Response) {
    const value = parse(openReviewSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.openReview(actorContext(req, true), {
        ...value,
        idempotencyKey: key,
      });
      return res.status(201).json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async assignReview(req: TenantRequest, res: Response) {
    const value = parse(assignReviewSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.assignReview(actorContext(req, true), {
        caseId: req.params.caseId,
        reviewerId: value.reviewerId,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async declareConflict(req: TenantRequest, res: Response) {
    const value = parse(conflictSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.declareReviewerConflict(actorContext(req, true), {
        caseId: req.params.caseId,
        conflictType: value.conflictType,
        note: value.note,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async decideReview(req: TenantRequest, res: Response) {
    const value = parse(decideReviewSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.decideReview(actorContext(req, true), {
        caseId: req.params.caseId,
        ...value,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async listAppeals(req: TenantRequest, res: Response) {
    const value = parse(queueSchema, req.query, res);
    if (!value) return;
    try {
      const data = await trustReviewService.listAppealQueue(actorContext(req, true), value);
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async decideAppeal(req: TenantRequest, res: Response) {
    const value = parse(decideAppealSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.decideAppeal(actorContext(req, true), {
        appealId: req.params.appealId,
        ...value,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async createRetentionDryRun(req: TenantRequest, res: Response) {
    const value = parse(retentionDryRunSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.createRetentionDryRun(actorContext(req, true), {
        organizationId: value.organizationId,
        policyId: value.policyId,
        idempotencyKey: key,
      });
      return res.status(202).json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async suspendOrganization(req: TenantRequest, res: Response) {
    const value = parse(organizationSuspensionSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.suspendOrganization(actorContext(req, true), {
        organizationId: req.params.organizationId,
        caseId: value.caseId,
        reasonCode: value.reasonCode,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },

  async resumeOrganization(req: TenantRequest, res: Response) {
    const value = parse(resumeSchema, req.body, res);
    if (!value) return;
    const key = commandKey(req, res);
    if (!key) return;
    try {
      const data = await trustReviewService.resumeOrganization(actorContext(req, true), {
        organizationId: req.params.organizationId,
        reasonCode: value.reasonCode,
        idempotencyKey: key,
      });
      return res.json({ success: true, data });
    } catch (error) {
      return commandFailure(res, error);
    }
  },
};
