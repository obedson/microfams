export const GROUP_COMMITTEE_ROLES = ['member', 'chair'] as const;
export const GROUP_MEETING_TYPES = ['general', 'committee', 'special', 'emergency'] as const;
export const GROUP_ATTENDANCE_STATUSES = ['present', 'absent', 'apology', 'proxy'] as const;

// A committee may only receive permissions the group itself can delegate. Anything
// that moves money or decides governance stays with GT-03 proposals and ballots.
export const GROUP_COMMITTEE_DELEGABLE_PERMISSIONS = [
  'groups.committee.recommend',
  'groups.committee.report',
  'groups.meeting.schedule',
  'groups.meeting.minute',
] as const;

export type GroupCommitteeRole = typeof GROUP_COMMITTEE_ROLES[number];
export type GroupMeetingType = typeof GROUP_MEETING_TYPES[number];
export type GroupAttendanceStatus = typeof GROUP_ATTENDANCE_STATUSES[number];
export type GroupCommitteePermission = typeof GROUP_COMMITTEE_DELEGABLE_PERMISSIONS[number];

export const GROUP_COMMITTEE_PROPOSAL_ACTIONS = ['create', 'amend', 'dissolve'] as const;
export type GroupCommitteeProposalAction = typeof GROUP_COMMITTEE_PROPOSAL_ACTIONS[number];

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const committeeKeyPattern = /^[a-z][a-z0-9_]{1,47}$/;
const reasonCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;

const record = (value: unknown) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
  }
  return value as Record<string, unknown>;
};

const optionalText = (value: unknown, code: string, max: number) => {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || value.length > max) throw new Error(code);
  return value;
};

const optionalDate = (value: unknown) => {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
  }
  return date.toISOString();
};

// Mirrors normalizeOfficeProposalPayload: the proposal stores the database
// contract, so a committee mandate is fixed at proposal time and cannot be
// reshaped between approval and execution.
export const normalizeCommitteeProposalPayload = (
  proposalType: string,
  payload: unknown,
): Record<string, unknown> => {
  if (proposalType !== 'committee_mandate') return record(payload);
  const value = record(payload);
  const action = value.action;
  if (typeof action !== 'string'
    || !GROUP_COMMITTEE_PROPOSAL_ACTIONS.includes(action as GroupCommitteeProposalAction)) {
    throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
  }

  if (action === 'create') {
    const committeeKey = value.committeeKey ?? value.committee_key;
    const displayName = value.displayName ?? value.display_name;
    const mandate = value.mandate;
    if (typeof committeeKey !== 'string' || !committeeKeyPattern.test(committeeKey)
      || typeof displayName !== 'string' || !displayName.length || displayName.length > 200
      || typeof mandate !== 'string' || !mandate.length || mandate.length > 5000) {
      throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
    }
    const ceiling = normalizeSpendingCeiling(
      value.spendingCeilingMinorUnits ?? value.spending_ceiling_minor_units,
      value.spendingCeilingCurrency ?? value.spending_ceiling_currency,
    );
    return {
      action,
      committee_key: committeeKey,
      display_name: displayName,
      mandate,
      delegated_permissions: normalizeCommitteePermissions(
        value.delegatedPermissions ?? value.delegated_permissions,
      ),
      spending_ceiling_minor_units: ceiling.minorUnits === null
        ? null : String(ceiling.minorUnits),
      spending_ceiling_currency: ceiling.currency,
      reporting_duties: optionalText(
        value.reportingDuties ?? value.reporting_duties,
        'GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID', 2000,
      ),
      term_ends_at: optionalDate(value.termEndsAt ?? value.term_ends_at),
    };
  }

  const committeeId = value.committeeId ?? value.committee_id;
  if (typeof committeeId !== 'string' || !uuidPattern.test(committeeId)) {
    throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
  }
  if (action === 'dissolve') {
    const reason = value.reasonCode ?? value.reason_code;
    if (typeof reason !== 'string' || !reasonCodePattern.test(reason)) {
      throw new Error('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
    }
    return { action, committee_id: committeeId, reason_code: reason };
  }

  const ceiling = normalizeSpendingCeiling(
    value.spendingCeilingMinorUnits ?? value.spending_ceiling_minor_units,
    value.spendingCeilingCurrency ?? value.spending_ceiling_currency,
  );
  return {
    action,
    committee_id: committeeId,
    delegated_permissions: normalizeCommitteePermissions(
      value.delegatedPermissions ?? value.delegated_permissions,
    ),
    spending_ceiling_minor_units: ceiling.minorUnits === null
      ? null : String(ceiling.minorUnits),
    spending_ceiling_currency: ceiling.currency,
  };
};

export interface QuorumInput {
  presentCount: number;
  eligibleCount: number;
  numerator: number;
  denominator: number;
}

const assertCount = (value: number, code: string) => {
  if (!Number.isInteger(value) || value < 0) throw new Error(code);
};

export const normalizeCommitteePermissions = (value: unknown): GroupCommitteePermission[] => {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new Error('GROUP_COMMITTEE_PERMISSIONS_INVALID');
  const allowed = new Set<string>(GROUP_COMMITTEE_DELEGABLE_PERMISSIONS);
  const normalized = new Set<GroupCommitteePermission>();
  for (const entry of value) {
    if (typeof entry !== 'string' || !allowed.has(entry)) {
      throw new Error('GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE');
    }
    normalized.add(entry as GroupCommitteePermission);
  }
  return [...normalized];
};

export const normalizeSpendingCeiling = (
  minorUnits: unknown,
  currency: unknown,
): { minorUnits: number | null; currency: string | null } => {
  if ((minorUnits === undefined || minorUnits === null)
    && (currency === undefined || currency === null)) {
    return { minorUnits: null, currency: null };
  }
  if (!Number.isInteger(minorUnits) || (minorUnits as number) < 0
    || typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
    throw new Error('GROUP_COMMITTEE_CEILING_INVALID');
  }
  return { minorUnits: minorUnits as number, currency };
};

// Only an emergency meeting may shorten the constitutional notice window, and the
// caller must supply a reason. Everything else fails closed.
export const assertMeetingNotice = (input: {
  meetingType: string;
  scheduledAt: string | Date;
  requiredNoticeHours: number;
  emergencyReason?: string | null;
  now?: Date;
}) => {
  const scheduled = input.scheduledAt instanceof Date
    ? input.scheduledAt : new Date(input.scheduledAt);
  const now = input.now ?? new Date();
  if (Number.isNaN(scheduled.getTime())
    || !Number.isInteger(input.requiredNoticeHours)
    || input.requiredNoticeHours < 0 || input.requiredNoticeHours > 8760) {
    throw new Error('GROUP_MEETING_COMMAND_INVALID');
  }
  if (scheduled.getTime() <= now.getTime()) {
    throw new Error('GROUP_MEETING_SCHEDULE_INVALID');
  }
  const isEmergency = input.meetingType === 'emergency';
  const hasReason = typeof input.emergencyReason === 'string'
    && input.emergencyReason.trim().length > 0;
  if (isEmergency !== hasReason) {
    throw new Error('GROUP_MEETING_EMERGENCY_REASON_REQUIRED');
  }
  if (!isEmergency) {
    const earliest = now.getTime() + input.requiredNoticeHours * 3_600_000;
    if (scheduled.getTime() < earliest) throw new Error('GROUP_MEETING_NOTICE_TOO_SHORT');
  }
  return scheduled.toISOString();
};

// Integer comparison only — never floating point ratios.
export const isQuorumMet = (input: QuorumInput): boolean => {
  assertCount(input.presentCount, 'GROUP_MEETING_QUORUM_INVALID');
  assertCount(input.eligibleCount, 'GROUP_MEETING_QUORUM_INVALID');
  if (!Number.isInteger(input.numerator) || !Number.isInteger(input.denominator)
    || input.numerator < 1 || input.denominator < 1
    || input.numerator > input.denominator
    || input.presentCount > input.eligibleCount) {
    throw new Error('GROUP_MEETING_QUORUM_INVALID');
  }
  return input.presentCount * input.denominator >= input.eligibleCount * input.numerator;
};
