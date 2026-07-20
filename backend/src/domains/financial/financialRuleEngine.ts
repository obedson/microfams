import {
  FinancialLimit,
  FinancialRule,
  FinancialRuleDecision,
  FinancialRuleFacts,
} from './financialRuleTypes.js';

const safeMinor = (value: number | undefined, name: string): number => {
  if (value === undefined) return 0;
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(name + ' must be a non-negative safe integer');
  return value;
};

const applies = (limit: FinancialLimit, facts: FinancialRuleFacts): string | undefined => {
  const amount = safeMinor(facts.amountMinor, 'Amount');
  if (limit.minimumMinor !== undefined && amount < limit.minimumMinor) return 'minimum_amount';
  const measured = {
    per_transaction: amount,
    rolling_period: safeMinor(facts.rollingAmountMinor, 'Rolling amount') + amount,
    calendar_day: safeMinor(facts.calendarDayAmountMinor, 'Calendar-day amount') + amount,
    balance: safeMinor(facts.balanceMinor, 'Balance') + amount,
    velocity: safeMinor(facts.velocityCount, 'Velocity count') + 1,
    beneficiary: safeMinor(facts.beneficiaryAmountMinor, 'Beneficiary amount') + amount,
    aggregate: safeMinor(facts.aggregateAmountMinor, 'Aggregate amount') + amount,
  }[limit.dimension];
  if (limit.maximumMinor !== undefined && measured > limit.maximumMinor) {
    return limit.dimension + '_maximum';
  }
  if (limit.maximumCount !== undefined && limit.dimension === 'velocity' && measured > limit.maximumCount) {
    return 'velocity_maximum';
  }
  return undefined;
};

export const evaluateFinancialRule = (
  rule: FinancialRule,
  facts: FinancialRuleFacts,
): FinancialRuleDecision => {
  safeMinor(facts.amountMinor, 'Amount');
  if (facts.amountMinor === 0) throw new Error('Amount must be positive');
  if (facts.currency !== (rule.currency ?? facts.currency)) {
    return { approved: false, reasons: ['currency_mismatch'], ruleId: rule.id, ruleVersion: rule.version };
  }
  if (facts.kycTier < (rule.minimumKycTier ?? 0)) {
    return { approved: false, reasons: ['kyc_tier_insufficient'], ruleId: rule.id, ruleVersion: rule.version };
  }
  const reasons = rule.limits.map((limit) => applies(limit, facts)).filter((reason): reason is string => Boolean(reason));
  return { approved: reasons.length === 0, reasons, ruleId: rule.id, ruleVersion: rule.version };
};
