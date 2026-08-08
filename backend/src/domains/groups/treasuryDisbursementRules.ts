export const GROUP_TREASURY_DISBURSEMENT_STATES = [
  'requested', 'approved', 'executed', 'rejected', 'cancelled', 'expired', 'reversed',
] as const;
// GT-06A settles internal beneficiaries only; the external provider channel
// arrives with GT-06B, which is why this list has a single member today.
export const GROUP_TREASURY_CHANNELS = ['internal'] as const;
export const GROUP_TREASURY_BENEFICIARY_KINDS = [
  'member', 'group', 'project',
] as const;
export const GROUP_TREASURY_RESERVATION_STATES = [
  'active', 'consumed', 'released', 'expired',
] as const;
export const GROUP_TREASURY_BUDGET_STATES = [
  'draft', 'active', 'exhausted', 'closed', 'cancelled',
] as const;

export type GroupTreasuryDisbursementState =
  typeof GROUP_TREASURY_DISBURSEMENT_STATES[number];
export type GroupTreasuryChannel = typeof GROUP_TREASURY_CHANNELS[number];
export type GroupTreasuryBeneficiaryKind =
  typeof GROUP_TREASURY_BENEFICIARY_KINDS[number];

const MAX_AMOUNT_MINOR = 100_000_000_000;

const reasonCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;
const currencyPattern = /^[A-Z]{3}$/;
// Mirrors the budget_key CHECK in install_group_treasury_disbursements.sql,
// which permits hyphens so keys like "ops-2026q3" are legal.
const budgetKeyPattern = /^[a-z][a-z0-9_-]{1,47}$/;

/**
 * The legal disbursement state graph, mirroring the migration's transition
 * guards. Executed is not terminal because a posted disbursement can still be
 * corrected by an opposing journal; every other end state is final, since a
 * rejected or expired request must be raised afresh rather than revived.
 */
const LEGAL_TRANSITIONS: Record<string, readonly string[]> = {
  requested: ['approved', 'rejected', 'cancelled', 'expired'],
  approved: ['executed', 'cancelled', 'expired'],
  executed: ['reversed'],
  rejected: [],
  cancelled: [],
  expired: [],
  reversed: [],
};

export const canTransitionDisbursement = (from: string, to: string): boolean =>
  (LEGAL_TRANSITIONS[from] ?? []).includes(to);

export const assertDisbursementTransition = (from: string, to: string) => {
  if (!canTransitionDisbursement(from, to)) {
    throw new Error('GROUP_TREASURY_DISBURSEMENT_TRANSITION_INVALID');
  }
  return to;
};

export interface DisbursementRequest {
  channel?: string;
  beneficiaryKind: string;
  beneficiaryMemberId?: string | null;
  beneficiaryUserId?: string | null;
  amountMinor: number;
  currency: string;
  purpose: string;
  evidenceUri?: string | null;
}

/**
 * Validates a spending request before it reaches the database, so a caller gets
 * a named error rather than a constraint violation. The beneficiary rules
 * mirror the table CHECKs: exactly one beneficiary reference must be set, and it
 * must be the one the declared kind calls for.
 */
export const validateDisbursementRequest = (input: DisbursementRequest) => {
  const channel = input.channel ?? 'internal';
  if (!GROUP_TREASURY_CHANNELS.includes(channel as GroupTreasuryChannel)) {
    throw new Error('GROUP_TREASURY_CHANNEL_INVALID');
  }
  if (!GROUP_TREASURY_BENEFICIARY_KINDS
    .includes(input.beneficiaryKind as GroupTreasuryBeneficiaryKind)) {
    throw new Error('GROUP_TREASURY_BENEFICIARY_KIND_INVALID');
  }
  if (!Number.isInteger(input.amountMinor)
    || input.amountMinor <= 0 || input.amountMinor > MAX_AMOUNT_MINOR) {
    throw new Error('GROUP_TREASURY_AMOUNT_INVALID');
  }
  if (typeof input.currency !== 'string' || !currencyPattern.test(input.currency)) {
    throw new Error('GROUP_TREASURY_CURRENCY_INVALID');
  }
  const purpose = typeof input.purpose === 'string' ? input.purpose.trim() : '';
  if (purpose.length < 1 || purpose.length > 1000) {
    throw new Error('GROUP_TREASURY_PURPOSE_REQUIRED');
  }

  // Clause 1: money leaving the group must name who receives it. A member
  // payout without a member row cannot be audited against the register.
  if (input.beneficiaryKind === 'member' && !input.beneficiaryMemberId) {
    throw new Error('GROUP_TREASURY_BENEFICIARY_MEMBER_REQUIRED');
  }
  if (input.beneficiaryKind !== 'member' && input.beneficiaryMemberId) {
    throw new Error('GROUP_TREASURY_BENEFICIARY_MEMBER_UNEXPECTED');
  }

  return {
    channel: channel as GroupTreasuryChannel,
    beneficiaryKind: input.beneficiaryKind as GroupTreasuryBeneficiaryKind,
    beneficiaryMemberId: input.beneficiaryMemberId ?? null,
    beneficiaryUserId: input.beneficiaryUserId ?? null,
    amountMinor: input.amountMinor,
    currency: input.currency,
    purpose,
    evidenceUri: input.evidenceUri ?? null,
  };
};

export interface SeparationOfDuties {
  requestedByUserId: string;
  checkerUserId: string;
  beneficiaryUserId?: string | null;
}

/**
 * Clause 3: the person who asks for money may not be the person who approves
 * it, and neither role may be filled by the person receiving it. Enforced here
 * as well as in SQL so an API caller is refused before a proposal is opened.
 */
export const assertSeparationOfDuties = (input: SeparationOfDuties) => {
  if (!input.requestedByUserId || !input.checkerUserId) {
    throw new Error('GROUP_TREASURY_SEPARATION_ACTORS_REQUIRED');
  }
  if (input.requestedByUserId === input.checkerUserId) {
    throw new Error('GROUP_TREASURY_MAKER_CANNOT_CHECK');
  }
  if (input.beneficiaryUserId) {
    if (input.beneficiaryUserId === input.requestedByUserId) {
      throw new Error('GROUP_TREASURY_BENEFICIARY_CANNOT_REQUEST');
    }
    if (input.beneficiaryUserId === input.checkerUserId) {
      throw new Error('GROUP_TREASURY_BENEFICIARY_CANNOT_CHECK');
    }
  }
  return true;
};

export interface FundsAvailability {
  availableMinor: number;
  amountMinor: number;
  budgetRemainingMinor?: number | null;
}

/**
 * Clause 2: funds are checked against what is available after existing
 * reservations, not against a raw balance, so two approvals cannot commit the
 * same money. A budget cap, when one applies, binds independently of the
 * treasury balance.
 */
export const assertFundsAvailable = (input: FundsAvailability) => {
  if (!Number.isInteger(input.availableMinor) || input.availableMinor < 0) {
    throw new Error('GROUP_TREASURY_AVAILABLE_INVALID');
  }
  if (!Number.isInteger(input.amountMinor) || input.amountMinor <= 0) {
    throw new Error('GROUP_TREASURY_AMOUNT_INVALID');
  }
  if (input.amountMinor > input.availableMinor) {
    throw new Error('GROUP_TREASURY_INSUFFICIENT_FUNDS');
  }
  if (input.budgetRemainingMinor !== undefined && input.budgetRemainingMinor !== null) {
    if (input.amountMinor > input.budgetRemainingMinor) {
      throw new Error('GROUP_TREASURY_BUDGET_EXCEEDED');
    }
  }
  return true;
};

export const validateReleaseReasonCode = (reasonCode: unknown) => {
  if (typeof reasonCode !== 'string' || !reasonCodePattern.test(reasonCode)) {
    throw new Error('GROUP_TREASURY_REASON_CODE_INVALID');
  }
  return reasonCode;
};

export const validateBudgetKey = (budgetKey: unknown) => {
  if (typeof budgetKey !== 'string' || !budgetKeyPattern.test(budgetKey)) {
    throw new Error('GROUP_TREASURY_BUDGET_KEY_INVALID');
  }
  return budgetKey;
};

export interface TreasuryPosition {
  balanceMinor: number;
  reservedMinor: number;
}

/**
 * Available funds are derived rather than stored, so the figure can never drift
 * from the reservations and journals it summarizes.
 */
export const summarizeTreasuryPosition = (position: TreasuryPosition) => {
  const balance = Number(position.balanceMinor ?? 0);
  const reserved = Number(position.reservedMinor ?? 0);
  return {
    balanceMinor: balance,
    reservedMinor: reserved,
    availableMinor: Math.max(balance - reserved, 0),
  };
};
