import { evaluateFinancialRule } from '../domains/financial/financialRuleEngine.js';
import { FinancialRule } from '../domains/financial/financialRuleTypes.js';

const rule: FinancialRule = {
  id: 'rule-1',
  version: 3,
  currency: 'NGN',
  minimumKycTier: 1,
  limits: [
    { dimension: 'per_transaction', minimumMinor: 10000, maximumMinor: 3000000 },
    { dimension: 'rolling_period', maximumMinor: 5000000, periodSeconds: 86400 },
    { dimension: 'velocity', maximumCount: 3, periodSeconds: 3600 },
  ],
};

describe('financial rule engine', () => {
  it('approves an eligible command and preserves the rule version', () => {
    expect(evaluateFinancialRule(rule, {
      amountMinor: 1000000,
      currency: 'NGN',
      kycTier: 1,
      rollingAmountMinor: 2000000,
      velocityCount: 1,
    })).toEqual({ approved: true, reasons: [], ruleId: 'rule-1', ruleVersion: 3 });
  });

  it('evaluates rolling amount and velocity including the proposed command', () => {
    const decision = evaluateFinancialRule(rule, {
      amountMinor: 2000000,
      currency: 'NGN',
      kycTier: 1,
      rollingAmountMinor: 4000000,
      velocityCount: 3,
    });
    expect(decision.approved).toBe(false);
    expect(decision.reasons).toEqual(['rolling_period_maximum', 'velocity_maximum']);
  });

  it('rejects currency and KYC mismatches before limit evaluation', () => {
    expect(evaluateFinancialRule(rule, {
      amountMinor: 100000,
      currency: 'USD',
      kycTier: 1,
    }).reasons).toEqual(['currency_mismatch']);
    expect(evaluateFinancialRule(rule, {
      amountMinor: 100000,
      currency: 'NGN',
      kycTier: 0,
    }).reasons).toEqual(['kyc_tier_insufficient']);
  });

  it('rejects unsafe money values', () => {
    expect(() => evaluateFinancialRule(rule, {
      amountMinor: 1.5,
      currency: 'NGN',
      kycTier: 1,
    })).toThrow('safe integer');
  });
});
