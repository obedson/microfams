export const GROUP_CONTRIBUTION_CYCLE_STATES = [
  'draft', 'open', 'grace', 'closing', 'closed', 'cancelled',
] as const;
export const GROUP_CONTRIBUTION_CYCLE_TRANSITIONS = ['grace', 'closing'] as const;
export const GROUP_CONTRIBUTION_OBLIGATION_STATES = [
  'open', 'satisfied', 'excess', 'waived', 'overdue', 'written_off',
] as const;
export const GROUP_CONTRIBUTION_ADJUSTMENT_KINDS = [
  'waiver', 'reduction', 'correction', 'write_off',
] as const;

export type GroupContributionCycleState = typeof GROUP_CONTRIBUTION_CYCLE_STATES[number];
export type GroupContributionCycleTransition =
  typeof GROUP_CONTRIBUTION_CYCLE_TRANSITIONS[number];
export type GroupContributionAdjustmentKind =
  typeof GROUP_CONTRIBUTION_ADJUSTMENT_KINDS[number];

const INVALID = 'GROUP_CONTRIBUTION_CYCLE_INVALID';
const MAX_AMOUNT_MINOR = 100_000_000_000;

const periodKeyPattern = /^[0-9]{4}(-[0-9]{2}){0,2}$/;
const reasonCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;
const isoDatePattern = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

/**
 * The legal cycle state graph, mirroring transition_group_contribution_cycle.
 * Closed and cancelled are terminal: clause 6 makes a closed cycle's financial
 * records immutable, so there is no edge out of either.
 */
const LEGAL_TRANSITIONS: Record<string, readonly string[]> = {
  draft: ['open', 'cancelled'],
  open: ['grace', 'closing', 'cancelled'],
  grace: ['closing', 'cancelled'],
  closing: ['closed', 'cancelled'],
  closed: [],
  cancelled: [],
};

export const canTransitionCycle = (from: string, to: string): boolean =>
  (LEGAL_TRANSITIONS[from] ?? []).includes(to);

export const assertCycleTransition = (from: string, to: string) => {
  if (!canTransitionCycle(from, to)) {
    throw new Error('GROUP_CONTRIBUTION_CYCLE_TRANSITION_INVALID');
  }
  return to;
};

const asDate = (value: unknown, code: string) => {
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) throw new Error(code);
    return value;
  }
  if (typeof value !== 'string' || !isoDatePattern.test(value)) throw new Error(code);
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) throw new Error(code);
  return parsed;
};

const isoDay = (value: Date) => value.toISOString().slice(0, 10);

export interface CycleWindow {
  periodKey: string;
  periodStart: string | Date;
  periodEnd: string | Date;
  dueDate: string | Date;
  timezone: string;
}

/**
 * Validates the billing window before it reaches the database. The ordering
 * rules mirror the table CHECKs: a period must not end before it starts, and a
 * cycle must not fall due before the period it bills for has begun. Catching it
 * here means a caller gets a specific error instead of a constraint violation.
 */
export const validateCycleWindow = (input: CycleWindow) => {
  if (typeof input.periodKey !== 'string' || !periodKeyPattern.test(input.periodKey)) {
    throw new Error('GROUP_CONTRIBUTION_PERIOD_KEY_INVALID');
  }
  if (typeof input.timezone !== 'string'
    || input.timezone.length < 3 || input.timezone.length > 64) {
    throw new Error('GROUP_CONTRIBUTION_TIMEZONE_INVALID');
  }

  const start = asDate(input.periodStart, 'GROUP_CONTRIBUTION_PERIOD_INVALID');
  const end = asDate(input.periodEnd, 'GROUP_CONTRIBUTION_PERIOD_INVALID');
  const due = asDate(input.dueDate, 'GROUP_CONTRIBUTION_DUE_DATE_INVALID');

  if (end.getTime() < start.getTime()) {
    throw new Error('GROUP_CONTRIBUTION_PERIOD_INVALID');
  }
  // Billing a member before the period they are billed for has started would
  // make the obligation unexplainable against its own cycle.
  if (due.getTime() < start.getTime()) {
    throw new Error('GROUP_CONTRIBUTION_DUE_DATE_INVALID');
  }

  return {
    periodKey: input.periodKey,
    periodStart: isoDay(start),
    periodEnd: isoDay(end),
    dueDate: isoDay(due),
    timezone: input.timezone,
  };
};

export interface ObligationAdjustment {
  adjustmentKind: string;
  deltaMinor: number;
  reasonCode: string;
  reason: string;
  evidence?: unknown;
}

/**
 * Clause 4: an obligation may be adjusted only by an authorized, evidenced
 * command. A waiver or write-off must clear the debt rather than partially
 * reduce it, and no adjustment may push an obligation below zero.
 */
export const validateObligationAdjustment = (
  input: ObligationAdjustment,
  currentOwedMinor: number,
) => {
  if (!GROUP_CONTRIBUTION_ADJUSTMENT_KINDS
    .includes(input.adjustmentKind as GroupContributionAdjustmentKind)) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_KIND_INVALID');
  }
  if (!Number.isInteger(input.deltaMinor) || input.deltaMinor === 0
    || Math.abs(input.deltaMinor) > MAX_AMOUNT_MINOR) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_DELTA_INVALID');
  }
  if (typeof input.reasonCode !== 'string' || !reasonCodePattern.test(input.reasonCode)) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_REASON_INVALID');
  }
  const reason = typeof input.reason === 'string' ? input.reason.trim() : '';
  if (reason.length < 1 || reason.length > 1000) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_REASON_INVALID');
  }
  if (!Number.isInteger(currentOwedMinor) || currentOwedMinor < 0) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_DELTA_INVALID');
  }
  if (currentOwedMinor + input.deltaMinor < 0) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_EXCEEDS_OBLIGATION');
  }
  // A waiver that leaves a balance behind is a reduction; naming it a waiver
  // would misrepresent what the group actually decided.
  if ((input.adjustmentKind === 'waiver' || input.adjustmentKind === 'write_off')
    && currentOwedMinor + input.deltaMinor !== 0) {
    throw new Error('GROUP_CONTRIBUTION_WAIVER_MUST_CLEAR_OBLIGATION');
  }
  if (input.evidence !== undefined && input.evidence !== null
    && (typeof input.evidence !== 'object' || Array.isArray(input.evidence))) {
    throw new Error('GROUP_CONTRIBUTION_ADJUSTMENT_EVIDENCE_INVALID');
  }

  return {
    adjustmentKind: input.adjustmentKind as GroupContributionAdjustmentKind,
    deltaMinor: input.deltaMinor,
    reasonCode: input.reasonCode,
    reason,
    evidence: (input.evidence ?? {}) as Record<string, unknown>,
  };
};

export interface CycleTotals {
  expectedMinor: number;
  receivedMinor: number;
  waivedMinor?: number;
  writtenOffMinor?: number;
  overdueMinor?: number;
  reversedMinor?: number;
  unreconciledExcessMinor?: number;
  refundedExcessMinor?: number;
}

/**
 * Clause 7: a dashboard must distinguish expected, received, pending, overdue,
 * waived, refunded, and unreconciled. Pending is derived here rather than
 * stored so it can never disagree with the two figures it sits between.
 */
export const summarizeCycleTotals = (totals: CycleTotals) => {
  const expected = Number(totals.expectedMinor ?? 0);
  const received = Number(totals.receivedMinor ?? 0);
  return {
    expectedMinor: expected,
    receivedMinor: received,
    pendingMinor: Math.max(expected - received, 0),
    waivedMinor: Number(totals.waivedMinor ?? 0),
    writtenOffMinor: Number(totals.writtenOffMinor ?? 0),
    overdueMinor: Number(totals.overdueMinor ?? 0),
    reversedMinor: Number(totals.reversedMinor ?? 0),
    unreconciledExcessMinor: Number(totals.unreconciledExcessMinor ?? 0),
    refundedExcessMinor: Number(totals.refundedExcessMinor ?? 0),
  };
};
