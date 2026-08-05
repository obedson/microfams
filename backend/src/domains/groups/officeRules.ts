export const GROUP_OFFICE_PROPOSAL_TYPES = ['office_appointment', 'office_removal'] as const;
export type GroupOfficeProposalType = typeof GROUP_OFFICE_PROPOSAL_TYPES[number];

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const officeKeyPattern = /^[a-z][a-z0-9_]{1,47}$/;
const reasonCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;

const record = (value: unknown) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
  }
  return value as Record<string, unknown>;
};

const optionalDate = (value: unknown) => {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new Error('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
  return date.toISOString();
};

export const normalizeOfficeProposalPayload = (
  proposalType: string,
  payload: unknown,
): Record<string, unknown> => {
  if (!GROUP_OFFICE_PROPOSAL_TYPES.includes(proposalType as GroupOfficeProposalType)) {
    return record(payload);
  }
  const value = record(payload);
  if (proposalType === 'office_appointment') {
    const officeKey = value.officeKey ?? value.office_key;
    const memberId = value.memberId ?? value.member_id;
    const termEndsAt = value.termEndsAt ?? value.term_ends_at;
    if (typeof officeKey !== 'string' || !officeKeyPattern.test(officeKey)
      || typeof memberId !== 'string' || !uuidPattern.test(memberId)) {
      throw new Error('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
    }
    return {
      office_key: officeKey,
      member_id: memberId,
      term_ends_at: optionalDate(termEndsAt),
    };
  }
  const assignmentId = value.assignmentId ?? value.assignment_id;
  const reasonCode = value.reasonCode ?? value.reason_code;
  if (typeof assignmentId !== 'string' || !uuidPattern.test(assignmentId)
    || typeof reasonCode !== 'string' || !reasonCodePattern.test(reasonCode)) {
    throw new Error('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
  }
  return { assignment_id: assignmentId, reason_code: reasonCode };
};

export const validateDelegationWindow = (
  startsAt: string | Date,
  endsAt: string | Date,
  maximumDays = 365,
) => {
  const starts = startsAt instanceof Date ? startsAt : new Date(startsAt);
  const ends = endsAt instanceof Date ? endsAt : new Date(endsAt);
  if (Number.isNaN(starts.getTime()) || Number.isNaN(ends.getTime())
    || !Number.isInteger(maximumDays) || maximumDays < 1 || maximumDays > 365) {
    throw new Error('GROUP_OFFICE_DELEGATION_WINDOW_INVALID');
  }
  const duration = ends.getTime() - starts.getTime();
  if (duration <= 0 || duration > maximumDays * 86_400_000) {
    throw new Error('GROUP_OFFICE_DELEGATION_WINDOW_INVALID');
  }
  return { startsAt: starts.toISOString(), endsAt: ends.toISOString() };
};
