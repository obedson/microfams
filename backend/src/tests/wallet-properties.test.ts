import { jest } from '@jest/globals';
import fc from 'fast-check';
import { ledgerService } from '../services/ledgerService.js';
import { walletService } from '../services/walletService.js';
import { interswitchService } from '../services/interswitchService.js';
import { supabase } from '../utils/supabase.js';

// Mock uuid
jest.mock('uuid', () => ({
  v4: jest.fn().mockReturnValue('mock-uuid'),
}));

// Mock Supabase
jest.mock('../utils/supabase.js', () => ({
  supabase: {
    from: jest.fn(),
    rpc: jest.fn().mockResolvedValue({ data: {}, error: null } as unknown as never),
  }
}));

// Mock other dependencies
jest.mock('../utils/audit.js', () => ({
  logAudit: jest.fn().mockResolvedValue(undefined as unknown as never),
}));

jest.mock('../services/emailService.js', () => ({
  sendEmail: jest.fn().mockResolvedValue(undefined as unknown as never),
}));

describe('Wallet System Property-Based Tests', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    (supabase.rpc as jest.Mock).mockResolvedValue({ data: {}, error: null } as unknown as never);
  });

  it('Property 2: Webhook Idempotency', async () => {
    const mockRpc = (supabase.rpc as jest.Mock);
    const mockFrom = (supabase.from as jest.Mock);

    await fc.assert(
      fc.asyncProperty(
        fc.record({
          reference: fc.uuid(),
          amount: fc.integer({ min: 100, max: 1000000 }),
          nuban: fc.string({ minLength: 10, maxLength: 10 }),
        }),
        async (data) => {
          jest.clearAllMocks();
          jest.spyOn(interswitchService, 'verifyWebhookSignature').mockReturnValue(true);

          mockFrom.mockImplementation(((table: string) => {
            if (table === 'wallet_transactions') {
              return {
                select: jest.fn().mockReturnValue({
                  eq: jest.fn().mockReturnValue({
                    single: jest.fn().mockImplementation(() => Promise.resolve({ data: null, error: { code: 'PGRST116' } }))
                  })
                })
              };
            }
            if (table === 'group_virtual_accounts') {
              return {
                select: jest.fn().mockReturnValue({
                  eq: jest.fn().mockReturnValue({
                    single: jest.fn().mockResolvedValue({ data: { group_id: 'group-123' }, error: null } as unknown as never)
                  })
                })
              };
            }
            return {
              select: jest.fn().mockReturnThis(),
              eq: jest.fn().mockReturnThis(),
              single: jest.fn().mockResolvedValue({ data: { creator_id: 'u-1', name: 'G' }, error: null } as unknown as never),
              insert: jest.fn().mockResolvedValue({ error: null } as unknown as never)
            };
          }) as any);

          await walletService.handleInterswitchWebhook({
            accountNumber: data.nuban,
            amount: data.amount,
            transactionReference: data.reference
          }, 'sig');
          
          expect(mockRpc).toHaveBeenCalledTimes(1);
        }
      ),
      { numRuns: 10 }
    );
  });

  it('Property 3: Webhook HMAC Validation', async () => {
    await fc.assert(
      fc.asyncProperty(
        fc.record({
          payload: fc.json(),
          useValidSig: fc.boolean(),
        }),
        async ({ payload, useValidSig }) => {
          jest.spyOn(interswitchService, 'verifyWebhookSignature').mockReturnValue(useValidSig);

          try {
            await walletService.handleInterswitchWebhook(JSON.parse(payload), 'sig');
          } catch (error: any) {
            if (!useValidSig) {
              expect(error.message).toBe('Invalid webhook signature');
            }
          }
        }
      ),
      { numRuns: 10 }
    );
  });
});
