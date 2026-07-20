import { supabase } from '../../utils/supabase.js';

export interface EnforceFinancialCommandInput {
  organizationId: string;
  actorId: string;
  commandType: string;
  commandId: string;
  product: string;
  channel: string;
  amountMinor: number;
  currency?: string;
  jurisdiction?: string;
  beneficiaryFingerprint?: string;
  balanceMinor?: number;
}

export class FinancialRuleService {
  async enforce(input: EnforceFinancialCommandInput) {
    if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor <= 0) {
      throw new Error('Financial command amount must be a positive safe integer in minor units');
    }
    const { data, error } = await supabase.rpc('enforce_financial_command', {
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_command_type: input.commandType,
      p_command_id: input.commandId,
      p_product: input.product,
      p_channel: input.channel,
      p_currency: input.currency ?? 'NGN',
      p_amount_minor: input.amountMinor,
      p_jurisdiction: input.jurisdiction ?? 'NG',
      p_beneficiary_fingerprint: input.beneficiaryFingerprint ?? null,
      p_balance_minor: input.balanceMinor ?? null,
    });
    if (error || !data) throw error ?? new Error('Financial compliance decision could not be recorded');
    if (!data.approved) {
      const reasons = Array.isArray(data.reasons) ? data.reasons.join(', ') : 'policy_denied';
      throw new Error('Financial command denied: ' + reasons);
    }
    return {
      snapshotId: data.snapshot_id as string,
      ruleVersionId: data.rule_version_id as string,
      ruleVersion: Number(data.rule_version),
    };
  }
}

export const financialRuleService = new FinancialRuleService();
