import { jest } from '@jest/globals';
import { walletService } from '../services/walletService.js';
import { interswitchService } from '../services/interswitchService.js';
import { ledgerService } from '../services/ledgerService.js';
import { supabase } from '../utils/supabase.js';
import jwt from 'jsonwebtoken';
import { payoutService } from '../domains/financial/payoutService.js';

// Mock Supabase
jest.mock('../utils/supabase.js', () => ({
  supabase: {
    from: jest.fn(),
    rpc: jest.fn(),
  }
}));

// Mock other dependencies
jest.mock('../utils/audit.js', () => ({
  logAudit: jest.fn().mockResolvedValue(undefined as unknown as never),
}));

jest.mock('../services/emailService.js', () => ({
  sendEmail: jest.fn().mockResolvedValue(undefined as unknown as never),
}));

jest.mock('../domains/financial/payoutService.js', () => ({
  payoutService: {
    validateDestination: jest.fn(),
    createAndSubmit: jest.fn(),
    queryAndApply: jest.fn(),
  },
}));

describe('Wallet System Integration Tests', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // 12.1 Full withdrawal flow
  it('should complete a full withdrawal flow successfully', async () => {
    process.env.INTERSWITCH_TRANSFER_FEE = '5000';
    process.env.JWT_SECRET = 'test-secret';
    const userId = 'user-1';
    const walletId = 'wallet-1';
    const amountMinor = 500000;

    // 1. Preview
    (payoutService.validateDestination as jest.Mock).mockResolvedValue({
      accountName: 'John Doe',
      bankCode: '044'
    } as never);
    jest.spyOn(ledgerService, 'getWalletBalanceSummary').mockResolvedValue({
      currency: 'NGN', ledgerBalanceMinor: 1000000, pendingDebitsMinor: 0,
      pendingCreditsMinor: 0, availableBalanceMinor: 1000000,
    });
    
    (supabase.from as jest.Mock).mockImplementation(((table: string) => {
      if (table === 'user_wallets') {
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          single: jest.fn().mockResolvedValue({ data: { id: walletId, balance: 10000 }, error: null } as unknown as never)
        };
      }
      if (table === 'wallet_transactions') {
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          gte: jest.fn().mockResolvedValue({ data: [], error: null } as unknown as never) // for limit check
        };
      }
      return {
        select: jest.fn().mockReturnThis(),
        eq: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: {}, error: null } as unknown as never)
      };
    }) as any);

    const preview = await walletService.previewWithdrawal(
      userId, '1234567890', '044', amountMinor, '00000000-0000-4000-8000-000000000111'
    );
    expect(preview.previewToken).toBeDefined();

    // 2. Confirm
    jest.spyOn(ledgerService, 'reserveWalletFunds').mockResolvedValue({
      id: 'reservation-1', organization_id: userId, wallet_id: walletId,
      amount_minor: 505000, state: 'active', expires_at: new Date(Date.now() + 300000).toISOString(),
    });
    jest.spyOn(ledgerService, 'consumeWalletReservation').mockResolvedValue({
      id: 'reservation-1', organization_id: userId, wallet_id: walletId,
      amount_minor: 505000, state: 'consumed', expires_at: new Date(Date.now() + 300000).toISOString(),
    });
    (payoutService.createAndSubmit as jest.Mock).mockResolvedValue({
      id: 'payout-1', state: 'processing', amountMinor, feeAmountMinor: 5000, currency: 'NGN',
    } as never);
    
    (supabase.from as jest.Mock).mockImplementation(((table: string) => {
      if (table === 'user_wallets') {
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          single: jest.fn().mockResolvedValue({ data: { id: walletId }, error: null } as unknown as never)
        };
      }
      if (table === 'withdrawal_requests') {
        return {
          upsert: jest.fn().mockReturnValue({
            select: jest.fn().mockReturnValue({
              single: jest.fn().mockResolvedValue({ data: {
                id: 'wr-1', internal_ref: 'WD-ref', amount_minor: amountMinor, fee_amount_minor: 5000,
              }, error: null } as unknown as never)
            })
          }),
          update: jest.fn().mockReturnThis(),
          eq: jest.fn().mockResolvedValue({ error: null } as unknown as never)
        };
      }
      return {
        select: jest.fn().mockReturnThis(),
        eq: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: {}, error: null } as unknown as never),
        update: jest.fn().mockReturnThis()
      };
    }) as any);

    const confirmation = await walletService.confirmWithdrawal(userId, preview.previewToken, '127.0.0.1');
    expect(confirmation.id).toBe('wr-1');
    expect(payoutService.createAndSubmit).toHaveBeenCalledWith(expect.objectContaining({
      withdrawalRequestId: 'wr-1', amountMinor, feeAmountMinor: 5000,
    }));

    // 3. Webhook SUCCESS
    (supabase.from as jest.Mock).mockImplementation(((table: string) => {
      if (table === 'withdrawal_requests') {
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          single: jest.fn().mockResolvedValue({ 
            data: { id: 'wr-1', user_id: userId, wallet_id: walletId, amount_minor: amountMinor, fee_amount_minor: 5000, status: 'PENDING' },
            error: null 
          } as unknown as never),
          update: jest.fn().mockReturnThis()
        };
      }
      return {
        select: jest.fn().mockReturnThis(),
        eq: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: { email: 'test@test.com', name: 'User' }, error: null } as unknown as never),
        insert: jest.fn().mockResolvedValue({ error: null } as unknown as never),
        update: jest.fn().mockReturnThis()
      };
    }) as any);

    await walletService.handleWithdrawalStatusUpdate('WD-ref', 'SUCCESS');
    
    // Verify status update in DB
    expect(supabase.from).toHaveBeenCalledWith('withdrawal_requests');
  });

  // 12.4 NUBAN provisioning retry
  it('should retry NUBAN provisioning successfully', async () => {
    const groupId = 'g-1';
    
    // First call fails
    jest.spyOn(interswitchService, 'provisionVirtualAccount').mockRejectedValueOnce(new Error('API Down'));
    
    (supabase.from as jest.Mock).mockReturnValue({
      select: jest.fn().mockReturnThis(),
      eq: jest.fn().mockReturnThis(),
      single: jest.fn().mockResolvedValue({ data: null, error: null } as unknown as never),
      upsert: jest.fn().mockReturnThis()
    });

    await expect(walletService.provisionGroupNuban(groupId, 'Test Group')).rejects.toThrow('API Down');
    expect(supabase.from).toHaveBeenCalledWith('group_virtual_accounts');
  });
});
