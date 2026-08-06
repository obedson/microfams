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
