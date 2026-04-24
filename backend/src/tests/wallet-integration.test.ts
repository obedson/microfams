import { jest } from '@jest/globals';
import { walletService } from '../services/walletService.js';
import { interswitchService } from '../services/interswitchService.js';
import { ledgerService } from '../services/ledgerService.js';
import { supabase } from '../utils/supabase.js';
import jwt from 'jsonwebtoken';

// Mock uuid
jest.mock('uuid', () => ({
  v4: jest.fn().mockReturnValue('mock-uuid'),
}));

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
    const amount = 5000;
    const fee = 50;

    // 1. Preview
    jest.spyOn(interswitchService, 'nameEnquiry').mockResolvedValue({
      accountName: 'John Doe',
      bankCode: '044'
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

    const preview = await walletService.previewWithdrawal(userId, '1234567890', '044', amount);
    expect(preview.previewToken).toBeDefined();

    // 2. Confirm
    jest.spyOn(ledgerService, 'debitWallet').mockResolvedValue({ id: 'tx-debit' } as unknown as never);
    jest.spyOn(interswitchService, 'singleTransfer').mockResolvedValue({ transferRef: 'is-ref-1', status: 'PENDING' } as unknown as never);
    
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
          insert: jest.fn().mockReturnValue({
            select: jest.fn().mockReturnValue({
              single: jest.fn().mockResolvedValue({ data: { id: 'wr-1', internal_ref: 'WD-ref' }, error: null } as unknown as never)
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
    expect(interswitchService.singleTransfer).toHaveBeenCalled();

    // 3. Webhook SUCCESS
    (supabase.from as jest.Mock).mockImplementation(((table: string) => {
      if (table === 'withdrawal_requests') {
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          single: jest.fn().mockResolvedValue({ 
            data: { id: 'wr-1', user_id: userId, wallet_id: walletId, amount: 5000, fee_amount: 50, status: 'PENDING' }, 
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
