import { jest } from '@jest/globals';
import { PayoutService } from '../domains/financial/payoutService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  supabase: {
    from: jest.fn(),
    rpc: jest.fn(),
  },
}));

describe('late booking payout success', () => {
  beforeEach(() => jest.clearAllMocks());

  it('records a reconciliation exception without reopening a terminal payout', async () => {
    const payout = {
      id: '00000000-0000-4000-8000-000000000991',
      organization_id: '00000000-0000-4000-8000-000000000992',
      source_type: 'booking_settlement',
      internal_reference: 'BSP-991',
      provider_name: 'sandbox',
      provider_environment: 'test',
      provider_reference: 'provider-old-991',
      amount_minor: 25_000,
      fee_amount_minor: 0,
      currency: 'NGN',
      beneficiary_masked: '******6789',
      beneficiary_fingerprint: 'a'.repeat(64),
      state: 'failed',
      failure_code: 'PROVIDER_FAILED',
      created_at: '2026-07-30T00:00:00.000Z',
      updated_at: '2026-07-30T00:05:00.000Z',
    };
    const query = {
      select: jest.fn().mockReturnThis(),
      eq: jest.fn().mockReturnThis(),
      single: jest.fn().mockResolvedValue({ data: payout, error: null } as never),
    };
    (supabase.from as jest.Mock).mockReturnValue(query);
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: { id: '00000000-0000-4000-8000-000000000993' },
      error: null,
    } as never);
    const service = new PayoutService(() => ({} as never), {} as never);

    const result = await (service as any).applyProviderResult(
      payout.id,
      'b'.repeat(64),
      {
        status: 'succeeded',
        providerReference: 'provider-late-991',
        amountMinor: 25_000,
        currency: 'NGN',
      },
    );

    expect(supabase.rpc).toHaveBeenCalledTimes(1);
    expect(supabase.rpc).toHaveBeenCalledWith(
      'record_booking_late_payout_success',
      expect.objectContaining({
        p_payout_id: payout.id,
        p_organization_id: payout.organization_id,
        p_provider_reference: 'provider-late-991',
        p_amount_minor: 25_000,
        p_currency: 'NGN',
      }),
    );
    expect(result).toEqual(expect.objectContaining({
      state: 'failed',
      reconciliationRequired: true,
      lateSuccessExceptionId: '00000000-0000-4000-8000-000000000993',
    }));
    expect(supabase.rpc).not.toHaveBeenCalledWith(
      'mark_payout_submitted',
      expect.anything(),
    );
  });
});
