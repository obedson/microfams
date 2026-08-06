import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { groupCommitteeService } from '../services/groupCommitteeService.js';
import {
  GROUP_ATTENDANCE_STATUSES,
  GROUP_COMMITTEE_DELEGABLE_PERMISSIONS,
  GROUP_COMMITTEE_ROLES,
  GROUP_MEETING_TYPES,
} from '../domains/groups/committeeRules.js';

const idempotencyKey = (req: TenantRequest) => {
  const value = req.header('Idempotency-Key');
  if (!value || !/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw Object.assign(new Error('A valid Idempotency-Key header is required.'), {
      statusCode: 400,
    });
  }
  return value;
};

const reasonCode = Joi.string().pattern(/^[A-Z][A-Z0-9_]{2,63}$/);

const committeeSchema = Joi.object({
  committeeKey: Joi.string().pattern(/^[a-z][a-z0-9_]{1,47}$/).required(),
  displayName: Joi.string().trim().min(1).max(200).required(),
  mandate: Joi.string().trim().min(1).max(5000).required(),
  delegatedPermissions: Joi.array()
    .items(Joi.string().valid(...GROUP_COMMITTEE_DELEGABLE_PERMISSIONS)).default([]),
  spendingCeilingMinorUnits: Joi.number().integer().min(0).allow(null),
  spendingCeilingCurrency: Joi.string().pattern(/^[A-Z]{3}$/).allow(null),
  reportingDuties: Joi.string().trim().max(2000).allow(null, ''),
  termEndsAt: Joi.date().iso().greater('now').allow(null),
})
  .and('spendingCeilingMinorUnits', 'spendingCeilingCurrency');

const committeeMemberSchema = Joi.object({
  memberId: Joi.string().uuid().required(),
  committeeRole: Joi.string().valid(...GROUP_COMMITTEE_ROLES).required(),
});

const reasonSchema = Joi.object({ reasonCode: reasonCode.required() });

const meetingSchema = Joi.object({
  meetingType: Joi.string().valid(...GROUP_MEETING_TYPES).required(),
  committeeId: Joi.string().uuid().allow(null),
  title: Joi.string().trim().min(1).max(500).required(),
  agenda: Joi.array().items(Joi.object()).default([]),
  scheduledAt: Joi.date().iso().greater('now').required(),
  requiredNoticeHours: Joi.number().integer().min(0).max(8760).required(),
  emergencyReason: Joi.string().trim().min(1).max(2000).allow(null),
  location: Joi.string().trim().max(500).allow(null, ''),
  quorumNumerator: Joi.number().integer().min(1).required(),
  quorumDenominator: Joi.number().integer().min(1).required(),
});

const attendanceSchema = Joi.object({
  memberId: Joi.string().uuid().required(),
  attendanceStatus: Joi.string().valid(...GROUP_ATTENDANCE_STATUSES).required(),
});

const holdSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
});

const cancelSchema = Joi.object({
  expectedVersion: Joi.number().integer().min(1).required(),
  reasonCode: reasonCode.required(),
});

const minutesSchema = Joi.object({
  content: Joi.string().trim().min(1).max(50_000).required(),
  resolutions: Joi.array().items(Joi.object()).default([]),
  correctsMinutesId: Joi.string().uuid().allow(null),
});

const routeUuid = (value: string, code: string) => {
  const result = Joi.string().uuid().required().validate(value);
  if (result.error) throw Object.assign(new Error(code), { statusCode: 400 });
  return result.value;
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
  if (message.includes('NOT_FOUND')) return 404;
  if (
    message.includes('CONFLICT')
    || message.includes('NOT_ACTIVE')
    || message.includes('ALREADY_SERVING')
    || message.includes('ALREADY_RECORDED')
    || message.includes('ALREADY_APPROVED')
    || message.includes('DRAFT_EXISTS')
    || message.includes('HAS_SCHEDULED_MEETINGS')
    || message.includes('TERM_EXPIRED')
    || message.includes('NOT_SCHEDULED')
    || message.includes('NOT_HELD')
    || message.includes('NOT_DRAFT')
    || message.includes('REQUIRED')
    || message.includes('NOT_ELIGIBLE')
    || message.includes('NOT_DELEGABLE')
    || message.includes('TOO_SHORT')
  ) return 409;
  if (message.includes('INVALID')) return 400;
  return 500;
};

const sendError = (res: Response, error: any) => {
  const known = /GROUP_[A-Z_]+/.test(error.message ?? '');
  return res.status(statusFor(error)).json({
    error: known ? error.message : 'Group committee command failed.',
  });
};

export const groupCommitteeController = {
  async createCommittee(req: TenantRequest, res: Response) {
    const { error, value } = committeeSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.createCommittee(context(req), {
        ...value,
        termEndsAt: value.termEndsAt ? value.termEndsAt.toISOString() : null,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async addMember(req: TenantRequest, res: Response) {
    const { error, value } = committeeMemberSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.addMember(context(req), {
        committeeId: routeUuid(req.params.committeeId, 'GROUP_COMMITTEE_ID_INVALID'),
        memberId: value.memberId,
        committeeRole: value.committeeRole,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async endMembership(req: TenantRequest, res: Response) {
    const { error, value } = reasonSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.endMembership(context(req), {
        membershipId: routeUuid(
          req.params.membershipId, 'GROUP_COMMITTEE_MEMBERSHIP_ID_INVALID',
        ),
        reasonCode: value.reasonCode,
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async dissolveCommittee(req: TenantRequest, res: Response) {
    const { error, value } = reasonSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.dissolveCommittee(context(req), {
        committeeId: routeUuid(req.params.committeeId, 'GROUP_COMMITTEE_ID_INVALID'),
        reasonCode: value.reasonCode,
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async getOverview(req: TenantRequest, res: Response) {
    try {
      const result = await groupCommitteeService.getCommitteeOverview(context(req));
      return res.json({ success: true, data: result });
    } catch (queryError) {
      return sendError(res, queryError);
    }
  },

  async scheduleMeeting(req: TenantRequest, res: Response) {
    const { error, value } = meetingSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.scheduleMeeting(context(req), {
        ...value,
        scheduledAt: value.scheduledAt.toISOString(),
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async recordAttendance(req: TenantRequest, res: Response) {
    const { error, value } = attendanceSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.recordAttendance(context(req), {
        meetingId: routeUuid(req.params.meetingId, 'GROUP_MEETING_ID_INVALID'),
        memberId: value.memberId,
        attendanceStatus: value.attendanceStatus,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async holdMeeting(req: TenantRequest, res: Response) {
    const { error, value } = holdSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.holdMeeting(context(req), {
        meetingId: routeUuid(req.params.meetingId, 'GROUP_MEETING_ID_INVALID'),
        expectedVersion: value.expectedVersion,
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async cancelMeeting(req: TenantRequest, res: Response) {
    const { error, value } = cancelSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.cancelMeeting(context(req), {
        meetingId: routeUuid(req.params.meetingId, 'GROUP_MEETING_ID_INVALID'),
        expectedVersion: value.expectedVersion,
        reasonCode: value.reasonCode,
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async draftMinutes(req: TenantRequest, res: Response) {
    const { error, value } = minutesSchema.validate(req.body, {
      abortEarly: false, stripUnknown: true,
    });
    if (error) return res.status(400).json({ error: error.message });
    try {
      const result = await groupCommitteeService.draftMinutes(context(req), {
        meetingId: routeUuid(req.params.meetingId, 'GROUP_MEETING_ID_INVALID'),
        content: value.content,
        resolutions: value.resolutions,
        correctsMinutesId: value.correctsMinutesId ?? null,
        idempotencyKey: idempotencyKey(req),
      });
      return res.status(201).json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async approveMinutes(req: TenantRequest, res: Response) {
    try {
      const result = await groupCommitteeService.approveMinutes(context(req), {
        minutesId: routeUuid(req.params.minutesId, 'GROUP_MEETING_MINUTES_ID_INVALID'),
        idempotencyKey: idempotencyKey(req),
      });
      return res.json({ success: true, data: result });
    } catch (commandError) {
      return sendError(res, commandError);
    }
  },

  async getMeeting(req: TenantRequest, res: Response) {
    try {
      const result = await groupCommitteeService.getMeetingRecord(
        context(req), routeUuid(req.params.meetingId, 'GROUP_MEETING_ID_INVALID'),
      );
      if (!result) return res.status(404).json({ error: 'GROUP_MEETING_NOT_FOUND' });
      return res.json({ success: true, data: result });
    } catch (queryError) {
      return sendError(res, queryError);
    }
  },
};
