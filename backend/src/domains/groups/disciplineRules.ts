export const GROUP_DISCIPLINE_ACTIONS = ['suspend', 'expel'] as const;
export const GROUP_DISCIPLINE_APPEAL_OUTCOMES = ['uphold', 'reinstate'] as const;

export type GroupDisciplineAction = typeof GROUP_DISCIPLINE_ACTIONS[number];
export type GroupDisciplineAppealOutcome = typeof GROUP_DISCIPLINE_APPEAL_OUTCOMES[number];

export interface DisciplineSchedule {
  noticeIssuedAt: string | Date;
  responseDueAt: string | Date;
  proposalClosesAt: string | Date;
  appealWindowDays: number;
}

const dateValue = (value: string | Date, code: string) => {
  const result = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(result.getTime())) throw new Error(code);
  return result;
};

export const validateDisciplineSchedule = (input: DisciplineSchedule) => {
  const notice = dateValue(input.noticeIssuedAt, 'GROUP_DISCIPLINE_NOTICE_DATE_INVALID');
  const response = dateValue(input.responseDueAt, 'GROUP_DISCIPLINE_RESPONSE_DATE_INVALID');
  const close = dateValue(input.proposalClosesAt, 'GROUP_DISCIPLINE_CLOSE_DATE_INVALID');
  const responseHours = (response.getTime() - notice.getTime()) / 3_600_000;
  const closeHours = (close.getTime() - response.getTime()) / 3_600_000;
  if (responseHours < 24 || responseHours > 24 * 30) {
    throw new Error('GROUP_DISCIPLINE_RESPONSE_WINDOW_INVALID');
  }
  if (closeHours <= 0 || closeHours > 24 * 30) {
    throw new Error('GROUP_DISCIPLINE_VOTE_WINDOW_INVALID');
  }
  if (!Number.isInteger(input.appealWindowDays)
    || input.appealWindowDays < 1 || input.appealWindowDays > 90) {
    throw new Error('GROUP_DISCIPLINE_APPEAL_WINDOW_INVALID');
  }
  return {
    noticeIssuedAt: notice.toISOString(),
    responseDueAt: response.toISOString(),
    proposalClosesAt: close.toISOString(),
    appealWindowDays: input.appealWindowDays,
  };
};

export const validateEvidenceRefs = (refs: unknown[], required: boolean) => {
  if (!Array.isArray(refs) || refs.length > 100 || (required && refs.length === 0)) {
    throw new Error('GROUP_DISCIPLINE_EVIDENCE_INVALID');
  }
  if (refs.some((value) => typeof value !== 'string' || value.trim().length === 0 || value.length > 500)) {
    throw new Error('GROUP_DISCIPLINE_EVIDENCE_INVALID');
  }
  return refs.map((value) => (value as string).trim());
};
