export const GROUP_CONTRIBUTION_PRODUCT_CLASSES = [
  'membership_fee', 'periodic_due', 'member_capital', 'project_subscription', 'savings',
] as const;
export const GROUP_CONTRIBUTION_OWNERSHIPS = [
  'group_income', 'member_attributed', 'project_restricted',
] as const;
export const GROUP_CONTRIBUTION_RAILS = [
  'paystack', 'interswitch', 'bank_transfer', 'cash_evidence', 'internal_wallet',
] as const;
export const GROUP_CONTRIBUTION_RULE_ACTIONS = ['adopt', 'supersede'] as const;

export type GroupContributionProductClass = typeof GROUP_CONTRIBUTION_PRODUCT_CLASSES[number];
export type GroupContributionOwnership = typeof GROUP_CONTRIBUTION_OWNERSHIPS[number];
export type GroupContributionRail = typeof GROUP_CONTRIBUTION_RAILS[number];

const INVALID = 'GROUP_CONTRIBUTION_PAYLOAD_INVALID';
const MAX_AMOUNT_MINOR = 100_000_000_000;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const productKeyPattern = /^[a-z][a-z0-9_]{1,47}$/;
const ruleCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;
const accountCodePattern = /^[A-Z0-9][A-Z0-9._-]{1,39}$/;

// Ownership is a function of the product class, never an independent choice. This
// mirrors the CHECK on group_contribution_rule_versions so a caller cannot get a
// member's capital recognized as group income.
const OWNERSHIP_BY_CLASS: Record<GroupContributionProductClass, GroupContributionOwnership> = {
  membership_fee: 'group_income',
  periodic_due: 'group_income',
  member_capital: 'member_attributed',
  savings: 'member_attributed',
  project_subscription: 'project_restricted',
};

export const ownershipForProductClass = (productClass: string): GroupContributionOwnership => {
  const ownership = OWNERSHIP_BY_CLASS[productClass as GroupContributionProductClass];
  if (!ownership) throw new Error('GROUP_CONTRIBUTION_CLASS_INVALID');
  return ownership;
};

const record = (value: unknown) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(INVALID);
  return value as Record<string, unknown>;
};

const text = (value: unknown, min: number, max: number) => {
  if (typeof value !== 'string') throw new Error(INVALID);
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) throw new Error(INVALID);
  return trimmed;
};

const pattern = (value: unknown, expression: RegExp) => {
  if (typeof value !== 'string' || !expression.test(value)) throw new Error(INVALID);
  return value;
};

const optionalCode = (value: unknown, required: boolean) => {
  if (value === undefined || value === null || value === '') {
    if (required) throw new Error(INVALID);
    return null;
  }
  return pattern(value, ruleCodePattern);
};

const amountMinor = (value: unknown) => {
  const amount = typeof value === 'string' ? Number(value) : value;
  if (typeof amount !== 'number' || !Number.isInteger(amount)
    || amount < 0 || amount > MAX_AMOUNT_MINOR) throw new Error(INVALID);
  return amount;
};

const rails = (value: unknown) => {
  if (!Array.isArray(value) || value.length < 1 || value.length > 8) throw new Error(INVALID);
  const unique = [...new Set(value)];
  if (unique.length !== value.length) throw new Error(INVALID);
  if (!unique.every((rail) => GROUP_CONTRIBUTION_RAILS
    .includes(rail as GroupContributionRail))) throw new Error(INVALID);
  return unique as GroupContributionRail[];
};

const jsonObject = (value: unknown) => {
  if (value === undefined || value === null) return {};
  return record(value);
};

/**
 * Normalizes a `contribution_rule` proposal payload into the exact shape
 * execute_group_contribution_rule_proposal reads. Disclosure is enforced here as
 * well as in the database so a proposal cannot be put to a vote without stating
 * ownership, withdrawal, and loss terms members are voting on.
 */
export const normalizeContributionProposalPayload = (
  proposalType: string,
  payload: unknown,
): Record<string, unknown> => {
  if (proposalType !== 'contribution_rule') return record(payload);
  const value = record(payload);

  const action = value.action;
  if (typeof action !== 'string'
    || !GROUP_CONTRIBUTION_RULE_ACTIONS.includes(action as 'adopt' | 'supersede')) {
    throw new Error(INVALID);
  }

  const productClass = value.productClass ?? value.product_class;
  if (typeof productClass !== 'string'
    || !GROUP_CONTRIBUTION_PRODUCT_CLASSES
      .includes(productClass as GroupContributionProductClass)) {
    throw new Error('GROUP_CONTRIBUTION_CLASS_INVALID');
  }
  const ownership = ownershipForProductClass(productClass);
  const memberAttributed = ownership === 'member_attributed';

  const projectId = value.projectId ?? value.project_id;
  if (productClass === 'project_subscription') {
    pattern(projectId, uuidPattern);
  } else if (projectId !== undefined && projectId !== null && projectId !== '') {
    throw new Error(INVALID);
  }

  const normalized: Record<string, unknown> = {
    action,
    product_class: productClass,
    purpose: text(value.purpose, 1, 2000),
    amount_minor: amountMinor(value.amountMinor ?? value.amount_minor),
    currency: pattern(value.currency, /^[A-Z]{3}$/),
    permitted_rails: rails(value.permittedRails ?? value.permitted_rails),
    payer_eligibility: jsonObject(value.payerEligibility ?? value.payer_eligibility),
    due_schedule: jsonObject(value.dueSchedule ?? value.due_schedule),
    refund_rule_code: pattern(value.refundRuleCode ?? value.refund_rule_code, ruleCodePattern),
    withdrawal_rule_code: optionalCode(
      value.withdrawalRuleCode ?? value.withdrawal_rule_code, memberAttributed,
    ),
    loss_allocation_rule_code: optionalCode(
      value.lossAllocationRuleCode ?? value.loss_allocation_rule_code, memberAttributed,
    ),
    revenue_account_code: pattern(
      value.revenueAccountCode ?? value.revenue_account_code, accountCodePattern,
    ),
    project_id: productClass === 'project_subscription' ? projectId : null,
  };

  // Member-attributed money may not carry terms that only make sense for it when
  // the class is group income; the database rejects it, so refuse it earlier.
  if (!memberAttributed
    && (normalized.withdrawal_rule_code !== null
      || normalized.loss_allocation_rule_code !== null)) {
    throw new Error(INVALID);
  }

  if (action === 'adopt') {
    normalized.product_key = pattern(value.productKey ?? value.product_key, productKeyPattern);
    normalized.display_name = text(value.displayName ?? value.display_name, 1, 200);
  } else {
    normalized.product_id = pattern(value.productId ?? value.product_id, uuidPattern);
  }
  return normalized;
};
