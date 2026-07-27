import { supabase } from '../../utils/supabase.js';

export type FinancialAccountPurpose =
  | 'operating_cash' | 'provider_clearing' | 'settlement_receivable' | 'loan_principal_receivable'
  | 'individual_wallet_funds' | 'group_wallet_funds' | 'pending_payout' | 'escrow_funds_held'
  | 'savings_principal' | 'savings_accrued_return' | 'investor_subscriptions_payable'
  | 'investor_redemptions_payable' | 'dividends_payable' | 'platform_fee_revenue'
  | 'provider_processing_fee' | 'credit_loss_writeoff' | 'opening_balance_equity' | 'retained_surplus';

export class FinancialAccountService {
  async provision(input: {
    organizationId: string; actorId: string; code: string; name: string;
    purpose: FinancialAccountPurpose; currency: string; ownerType: string;
    ownerId?: string; effectiveFrom: string; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('provision_financial_account', {
      p_organization: input.organizationId, p_actor: input.actorId, p_code: input.code,
      p_name: input.name, p_purpose: input.purpose, p_currency: input.currency,
      p_owner_type: input.ownerType, p_owner_id: input.ownerId ?? null,
      p_effective_from: input.effectiveFrom, p_key: input.idempotencyKey,
    });
    if (error || !data) throw error ?? new Error('Financial account could not be provisioned');
    return data;
  }
}

export const financialAccountService = new FinancialAccountService();
