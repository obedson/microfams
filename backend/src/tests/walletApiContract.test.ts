import { jest } from '@jest/globals';
import { walletController } from '../controllers/walletController.js';
import { walletService } from '../services/walletService.js';
import { payoutService } from '../domains/financial/payoutService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../services/walletService.js', () => ({
  walletService: {
    previewWithdrawal: jest.fn(),
    handleInterswitchWebhook: jest.fn(),
  },
}));

jest.mock('../domains/financial/payoutService.js', () => ({
  payoutService: { ingestWebhook: jest.fn() },
}));

jest.mock('../utils/supabase.js', () => ({
  supabase: { rpc: jest.fn(), from: jest.fn() },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  res.sendStatus = jest.fn().mockReturnValue(res);
  return res;
};

describe('wallet API minor-unit contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects the legacy major-unit withdrawal payload', async () => {
    const req: any = {
      body: { accountNumber: '1234567890', bankCode: '044', amount: 1000 },
      user: { id: '00000000-0000-4000-8000-000000000101' },
      tenant: { id: '00000000-0000-4000-8000-000000000101' },
    };
    const res = response();

    await walletController.previewWithdrawal(req, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(walletService.previewWithdrawal).not.toHaveBeenCalled();
  });

  it('accepts an integer NGN minor-unit withdrawal command', async () => {
    (walletService.previewWithdrawal as jest.Mock).mockResolvedValue({
      accountName: 'Test Beneficiary', feeMinor: 5000, currency: 'NGN', previewToken: 'token',
    } as never);
    const req: any = {
      body: {
        accountNumber: '1234567890', bankCode: '044', amountMinor: 100000,
        currency: 'NGN', idempotencyKey: '00000000-0000-4000-8000-000000000111',
      },
      user: { id: '00000000-0000-4000-8000-000000000101' },
      tenant: { id: '00000000-0000-4000-8000-000000000101' },
    };
    const res = response();

    await walletController.previewWithdrawal(req, res);

    expect(walletService.previewWithdrawal).toHaveBeenCalledWith(
      req.user.id, '1234567890', '044', 100000,
      '00000000-0000-4000-8000-000000000111', req.tenant.id,
    );
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ feeMinor: 5000, currency: 'NGN' }));
  });

  it('passes the authenticated tenant and a reproducible cutoff to the statement RPC', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: {
        account: {
          id: '00000000-0000-4000-8000-000000000201',
          name: 'Member wallet', currency: 'NGN', normalSide: 'credit',
        },
        openingBalanceMinor: '10000', pageOpeningBalanceMinor: '10000',
        closingBalanceMinor: '10000', lines: [], total: 0,
      },
      error: null,
    } as never);
    const cutoff = new Date(Date.now() - 60_000).toISOString();
    const req: any = {
      query: { from: '2026-07-01', to: '2026-07-27', cutoff, page: '1', limit: '25' },
      user: { id: '00000000-0000-4000-8000-000000000101' },
      tenant: { id: '00000000-0000-4000-8000-000000000102' },
    };
    const res = response();

    await walletController.getStatement(req, res);

    expect(supabase.rpc).toHaveBeenCalledWith('read_financial_statement', expect.objectContaining({
      p_organization_id: req.tenant.id,
      p_owner_type: 'user',
      p_owner_id: req.user.id,
      p_cutoff: cutoff,
    }));
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ closingBalanceMinor: '10000' }));
  });

  it('rejects invalid statement dates before querying financial storage', async () => {
    const req: any = {
      query: { from: '2026-02-30', to: '2026-07-27' },
      user: { id: '00000000-0000-4000-8000-000000000101' },
      tenant: { id: '00000000-0000-4000-8000-000000000102' },
    };
    const res = response();

    await walletController.getStatement(req, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('returns a controlled response when statement storage is unavailable', async () => {
    (supabase.rpc as jest.Mock).mockRejectedValue(new Error('storage unavailable') as never);
    const req: any = {
      query: {}, user: { id: '00000000-0000-4000-8000-000000000101' },
      tenant: { id: '00000000-0000-4000-8000-000000000102' },
    };
    const res = response();
    await walletController.getStatement(req, res);
    expect(res.status).toHaveBeenCalledWith(500);
  });

  it('requires the original raw payout webhook body', async () => {
    const res = response();
    await walletController.payoutWebhook({
      body: { status: 'succeeded' }, headers: { 'x-interswitch-signature': 'abcd' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(payoutService.ingestWebhook).not.toHaveBeenCalled();
  });

  it('passes exact raw payout webhook bytes to the verifier', async () => {
    (payoutService.ingestWebhook as jest.Mock).mockResolvedValue({ state: 'succeeded' } as never);
    const rawBody = Buffer.from('{"reference":"WD-test"}');
    const res = response();
    await walletController.payoutWebhook({
      body: rawBody, headers: { 'x-interswitch-signature': 'abcd' },
    } as any, res);
    expect(payoutService.ingestWebhook).toHaveBeenCalledWith(rawBody, 'abcd');
    expect(res.sendStatus).toHaveBeenCalledWith(200);
  });

  it('requires and preserves the raw collection webhook body', async () => {
    const invalidResponse = response();
    await walletController.interswitchWebhook({
      body: { transactionReference: 'collection-1' },
      headers: { 'x-interswitch-signature': 'abcd' },
    } as any, invalidResponse);
    expect(invalidResponse.status).toHaveBeenCalledWith(400);

    const rawBody = Buffer.from('{"transactionReference":"collection-1"}');
    const validResponse = response();
    await walletController.interswitchWebhook({
      body: rawBody, headers: { 'x-interswitch-signature': 'abcd' },
    } as any, validResponse);
    expect(walletService.handleInterswitchWebhook).toHaveBeenCalledWith(rawBody, 'abcd');
    expect(validResponse.sendStatus).toHaveBeenCalledWith(200);
  });
});
