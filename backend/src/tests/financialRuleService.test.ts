import { jest } from '@jest/globals';
import { FinancialRuleService } from '../domains/financial/financialRuleService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  supabase: { rpc: jest.fn() },
}));

describe('financial rule service', () => {
  beforeEach(() => jest.clearAllMocks());

  it('passes tenant, command, money and beneficiary facts to the database boundary', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: { approved: true, snapshot_id: 'snapshot-1', rule_version_id: 'rule-1', rule_version: 7 },
      error: null,
    } as never);
    const result = await new FinancialRuleService().enforce({
      organizationId: 'org-1',
      actorId: 'actor-1',
      commandType: 'wallet.p2p',
      commandId: 'command-1',
      product: 'wallet',
      channel: 'p2p',
      amountMinor: 125000,
      beneficiaryFingerprint: 'fingerprint',
    });
    expect(supabase.rpc).toHaveBeenCalledWith('enforce_financial_command', expect.objectContaining({
      p_organization_id: 'org-1',
      p_actor_id: 'actor-1',
      p_amount_minor: 125000,
      p_currency: 'NGN',
      p_beneficiary_fingerprint: 'fingerprint',
    }));
    expect(result).toEqual({ snapshotId: 'snapshot-1', ruleVersionId: 'rule-1', ruleVersion: 7 });
  });

  it('fails closed with the recorded policy reasons', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: { approved: false, reasons: ['risk_control_active', 'rolling_period_maximum'] },
      error: null,
    } as never);
    await expect(new FinancialRuleService().enforce({
      organizationId: 'org-1',
      actorId: 'actor-1',
      commandType: 'wallet.p2p',
      commandId: 'command-2',
      product: 'wallet',
      channel: 'p2p',
      amountMinor: 125000,
    })).rejects.toThrow('risk_control_active, rolling_period_maximum');
  });

  it('rejects invalid minor-unit values before database access', async () => {
    await expect(new FinancialRuleService().enforce({
      organizationId: 'org-1',
      actorId: 'actor-1',
      commandType: 'wallet.p2p',
      commandId: 'command-3',
      product: 'wallet',
      channel: 'p2p',
      amountMinor: 1.25,
    })).rejects.toThrow('safe integer');
    expect(supabase.rpc).not.toHaveBeenCalled();
  });
});
