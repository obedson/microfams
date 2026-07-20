export type FinancialRuleDimension =
  | 'per_transaction'
  | 'rolling_period'
  | 'calendar_day'
  | 'balance'
  | 'velocity'
  | 'beneficiary'
  | 'aggregate';

export interface FinancialLimit {
  dimension: FinancialRuleDimension;
  minimumMinor?: number;
  maximumMinor?: number;
  periodSeconds?: number;
  maximumCount?: number;
}

export interface FinancialRule {
  id: string;
  version: number;
  jurisdiction?: string;
  product?: string;
  channel?: string;
  currency?: string;
  minimumKycTier?: number;
  limits: FinancialLimit[];
}

export interface FinancialRuleFacts {
  amountMinor: number;
  currency: string;
  kycTier: number;
  balanceMinor?: number;
  rollingAmountMinor?: number;
  calendarDayAmountMinor?: number;
  aggregateAmountMinor?: number;
  velocityCount?: number;
  beneficiaryAmountMinor?: number;
}

export interface FinancialRuleDecision {
  approved: boolean;
  reasons: string[];
  ruleId: string;
  ruleVersion: number;
}
