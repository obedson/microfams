import { jest } from '@jest/globals';
import { interswitchService } from '../services/interswitchService.js';
import { walletService } from '../services/walletService.js';
import { ledgerService } from '../services/ledgerService.js';
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
      await expect(walletService.previewWithdrawal('u-1', '1234567890', '044', 500))
        .rejects.toThrow('Minimum withdrawal amount is ₦1,000');
    });

    it('should include fee and return preview token', async () => {
      process.env.INTERSWITCH_TRANSFER_FEE = '5000';
      process.env.JWT_SECRET = 'test-secret';

      jest.spyOn(interswitchService, 'nameEnquiry').mockResolvedValue({
        accountName: 'John Doe',
        bankCode: '044'
      });

      (supabase.from as jest.Mock).mockReturnValue({
        select: jest.fn().mockReturnThis(),
        eq: jest.fn().mockReturnThis(),
        single: jest.fn().mockResolvedValue({ data: { balance: 2000 }, error: null } as unknown as never),
        gte: jest.fn().mockResolvedValue({ data: [], error: null } as unknown as never)
      });

      const result = await walletService.previewWithdrawal('u-1', '1234567890', '044', 1000);

      expect(result.accountName).toBe('John Doe');
      expect(result.fee).toBe(50);
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
});
