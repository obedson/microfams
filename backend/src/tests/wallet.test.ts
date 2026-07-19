import { jest } from '@jest/globals';
import { interswitchService } from '../services/interswitchService.js';
import { walletService } from '../services/walletService.js';
import { ledgerService } from '../services/ledgerService.js';
import { payoutService } from '../domains/financial/payoutService.js';
import { supabase } from '../utils/supabase.js';
import axios from 'axios';
import crypto from 'crypto';
import jwt from 'jsonwebtoken';

// Mock axios
jest.mock('axios');
const mockedAxios = axios as jest.Mocked<typeof axios>;

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

describe('Wallet System Unit Tests', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (interswitchService as any).tokenCache = null;
  });

  describe('InterswitchService', () => {
    it('should fetch and cache token', async () => {
      mockedAxios.post.mockResolvedValueOnce({
        data: { access_token: 'test-token', expires_in: 3600 }
      });

      const token1 = await interswitchService.getAccessToken();
      const token2 = await interswitchService.getAccessToken();

      expect(token1).toBe('test-token');
      expect(token2).toBe('test-token');
      expect(mockedAxios.post).toHaveBeenCalledTimes(1);
    });

    it('should verify valid webhook signature', () => {
      const payload = JSON.stringify({ test: 'data' });
      const secret = 'test-secret';
      (interswitchService as any).webhookSecret = secret;
      
      const signature = crypto
        .createHmac('sha512', secret)
        .update(payload)
        .digest('hex');

      expect(interswitchService.verifyWebhookSignature(payload, signature)).toBe(true);
    });
  });

  describe('WalletService.previewWithdrawal', () => {
    it('should reject amount < 1000', async () => {
      await expect(walletService.previewWithdrawal('u-1', '1234567890', '044', 50000, 'preview-key'))
        .rejects.toThrow('Minimum withdrawal amount is ₦1,000');
    });

    it('should include fee and return preview token', async () => {
      process.env.INTERSWITCH_TRANSFER_FEE = '5000';
      process.env.JWT_SECRET = 'test-secret';

      jest.spyOn(payoutService, 'validateDestination').mockResolvedValue({
        accountName: 'John Doe',
        bankCode: '044'
      });
      jest.spyOn(ledgerService, 'getWalletBalanceSummary').mockResolvedValue({
        currency: 'NGN', ledgerBalanceMinor: 200000, pendingDebitsMinor: 0,
        pendingCreditsMinor: 0, availableBalanceMinor: 200000,
      });

      (supabase.from as jest.Mock).mockReturnValue({
        select: jest.fn().mockReturnThis(),
        eq: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: { id: 'wallet-1' }, error: null } as unknown as never),
        gte: jest.fn().mockResolvedValue({ data: [], error: null } as unknown as never)
      });

      const result = await walletService.previewWithdrawal('u-1', '1234567890', '044', 100000, 'preview-key');

      expect(result.accountName).toBe('John Doe');
      expect(result.feeMinor).toBe(5000);
      expect(result.previewToken).toBeDefined();
    });
  });

  describe('Interswitch Webhook Handler', () => {
    it('should return early for duplicate reference', async () => {
      jest.spyOn(interswitchService, 'verifyWebhookSignature').mockReturnValue(true);
      
      (supabase.from as jest.Mock).mockImplementation(((table: string) => {
        if (table === 'wallet_transactions') {
          return {
            select: jest.fn().mockReturnThis(),
            eq: jest.fn().mockReturnThis(),
            single: jest.fn().mockResolvedValue({ data: { id: 'tx-1' }, error: null } as unknown as never)
          };
        }
        return {
          select: jest.fn().mockReturnThis(),
          eq: jest.fn().mockReturnThis(),
          single: jest.fn().mockResolvedValue({ data: {}, error: null } as unknown as never)
        };
      }) as any);

      const mockRpc = (supabase.rpc as jest.Mock);
      
      await walletService.handleInterswitchWebhook({ transactionReference: 'dup-1' }, 'sig');
      
      expect(mockRpc).not.toHaveBeenCalled();
    });
  });

  describe('tenant wallet provisioning', () => {
    it('uses organization and user as the wallet identity', async () => {
      const upsert = jest.fn().mockReturnThis();
      (supabase.from as jest.Mock).mockReturnValue({
        upsert,
        select: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: { id: 'wallet-1' }, error: null } as unknown as never),
      });

      await walletService.provisionUserWallet('user-1', 'org-1');

      expect(upsert).toHaveBeenCalledWith(
        { user_id: 'user-1', organization_id: 'org-1' },
        { onConflict: 'organization_id,user_id' },
      );
    });

    it('uses the personal organization during registration', async () => {
      const upsert = jest.fn().mockReturnThis();
      (supabase.from as jest.Mock).mockReturnValue({ upsert, select: jest.fn().mockReturnThis(), single: jest.fn().mockResolvedValue({ data: {}, error: null } as unknown as never) });
      await walletService.provisionUserWallet('user-1');
      expect(upsert).toHaveBeenCalledWith(expect.objectContaining({ organization_id: 'user-1' }), expect.anything());
    });
  });

  describe('tenant isolation', () => {
    it('scopes wallet and transaction history to the active organization', async () => {
      const eq = jest.fn().mockReturnThis();
      const single = jest.fn().mockResolvedValue({
        data: { id: 'wallet-1', organization_id: 'org-1' }, error: null
      } as unknown as never);
      const range = jest.fn().mockResolvedValue({ data: [], count: 0, error: null } as unknown as never);
      (supabase.from as jest.Mock).mockReturnValue({
        select: jest.fn().mockReturnThis(),
        eq,
        single,
        order: jest.fn().mockReturnThis(),
        range
      });

      await walletService.getWalletWithHistory('user-1', 1, 10, 'org-1');

      expect(eq).toHaveBeenCalledWith('organization_id', 'org-1');
      expect(eq).toHaveBeenCalledWith('wallet_id', 'wallet-1');
    });
  });
});
