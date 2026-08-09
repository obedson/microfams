export const GROUP_TREASURY_DISBURSEMENT_STATES = [
  'requested', 'approved', 'disbursing', 'executed',
  'rejected', 'cancelled', 'expired', 'failed', 'reversed',
] as const;
// An internal disbursement posts a balanced journal the moment it executes.
// An external one hands the money to a provider and cannot know the outcome
// synchronously, so GT-06B adds the 'external' channel and the intermediate
// 'disbursing'/'failed' states that channel needs.
export const GROUP_TREASURY_CHANNELS = ['internal', 'external'] as const;
export const GROUP_TREASURY_BENEFICIARY_KINDS = [
  'member', 'group', 'project', 'external',
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
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
// A Nigerian NUBAN is ten digits; provider bank codes are short numeric strings.
// The provider still verifies the pair, but an obviously malformed destination
// is refused before it reaches the registry.
const nubanPattern = /^\d{10}$/;
const bankCodePattern = /^\d{3,6}$/;
// Mirrors the budget_key CHECK in install_group_treasury_disbursements.sql,
// which permits hyphens so keys like "ops-2026q3" are legal.
const budgetKeyPattern = /^[a-z][a-z0-9_-]{1,47}$/;

/**
 * The legal disbursement state graph, mirroring the migration's transition
 * guards. An internal disbursement settles straight from `approved` to
 * `executed`; an external one passes through `disbursing` while the provider
 * payout is in flight, then reaches `executed` on confirmed success or `failed`
 * when the provider declines or times out and the reservation is released.
 * Executed is not terminal because a posted disbursement can still be corrected
 * by an opposing journal; every other end state is final, since a rejected,
 * failed, or expired request must be raised afresh rather than revived.
 */
const LEGAL_TRANSITIONS: Record<string, readonly string[]> = {
  requested: ['approved', 'rejected', 'cancelled', 'expired'],
  approved: ['executed', 'disbursing', 'cancelled', 'expired'],
  disbursing: ['executed', 'failed'],
  executed: ['reversed'],
  rejected: [],
  cancelled: [],
  expired: [],
  failed: [],
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
  externalBeneficiaryId?: string | null;
  amountMinor: number;
  currency: string;
  purpose: string;
  evidenceUri?: string | null;
}

// The shared payout adapter submits NGN only (PayoutSubmissionCommand.currency),
// so an external disbursement inherits that constraint until the adapter is
// generalized. Internal disbursements remain multi-currency at the budget level.
export const GROUP_TREASURY_EXTERNAL_CURRENCIES = ['NGN'] as const;

/**
 * Validates a spending request before it reaches the database, so a caller gets
 * a named error rather than a constraint violation. The beneficiary rules
 * mirror the table CHECKs: exactly one beneficiary reference must be set, and it
 * must be the one the declared kind calls for. The channel and the kind must
 * agree — an external channel pays a verified off-platform account and nothing
 * else, so a mismatch could reserve funds for one destination and pay another.
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
  const isExternal = channel === 'external';
  if (isExternal !== (input.beneficiaryKind === 'external')) {
    throw new Error('GROUP_TREASURY_CHANNEL_BENEFICIARY_MISMATCH');
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

  if (isExternal) {
    // The provider path settles NGN only.
    if (!(GROUP_TREASURY_EXTERNAL_CURRENCIES as readonly string[]).includes(input.currency)) {
      throw new Error('GROUP_TREASURY_EXTERNAL_CURRENCY_UNSUPPORTED');
    }
    // Clause 6: an external disbursement names a verified beneficiary, never a
    // member row. Verification and destination custody live in the registry.
    if (typeof input.externalBeneficiaryId !== 'string'
      || !uuidPattern.test(input.externalBeneficiaryId)) {
      throw new Error('GROUP_TREASURY_EXTERNAL_BENEFICIARY_INVALID');
    }
    if (input.beneficiaryMemberId) {
      throw new Error('GROUP_TREASURY_BENEFICIARY_MEMBER_UNEXPECTED');
    }
    return {
      channel: channel as GroupTreasuryChannel,
      beneficiaryKind: 'external' as GroupTreasuryBeneficiaryKind,
      beneficiaryMemberId: null,
      beneficiaryUserId: null,
      externalBeneficiaryId: input.externalBeneficiaryId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      purpose,
      evidenceUri: input.evidenceUri ?? null,
    };
  }

  // Clause 1: money leaving the group must name who receives it. A member
  // payout without a member row cannot be audited against the register.
  if (input.externalBeneficiaryId) {
    throw new Error('GROUP_TREASURY_EXTERNAL_BENEFICIARY_UNEXPECTED');
  }
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
    externalBeneficiaryId: null,
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

export interface ExternalBeneficiaryRegistration {
  accountNumber: string;
  bankCode: string;
  accountName: string;
  currency: string;
}

/**
 * Clause 6 / GT-11: an external destination is verified and held before any
 * money is committed to it. The registry owns custody; this checks the shape of
 * a registration before the provider is asked to confirm the account, and pins
 * the currency to the one the shared adapter can settle.
 */
export const validateExternalBeneficiary = (input: ExternalBeneficiaryRegistration) => {
  if (typeof input.accountNumber !== 'string' || !nubanPattern.test(input.accountNumber)) {
    throw new Error('GROUP_TREASURY_EXTERNAL_ACCOUNT_INVALID');
  }
  if (typeof input.bankCode !== 'string' || !bankCodePattern.test(input.bankCode)) {
    throw new Error('GROUP_TREASURY_EXTERNAL_BANK_CODE_INVALID');
  }
  const accountName = typeof input.accountName === 'string' ? input.accountName.trim() : '';
  if (accountName.length < 2 || accountName.length > 200) {
    throw new Error('GROUP_TREASURY_EXTERNAL_ACCOUNT_NAME_INVALID');
  }
  if (typeof input.currency !== 'string'
    || !(GROUP_TREASURY_EXTERNAL_CURRENCIES as readonly string[]).includes(input.currency)) {
    throw new Error('GROUP_TREASURY_EXTERNAL_CURRENCY_UNSUPPORTED');
  }
  return {
    accountNumber: input.accountNumber,
    bankCode: input.bankCode,
    accountName,
    currency: input.currency,
  };
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
