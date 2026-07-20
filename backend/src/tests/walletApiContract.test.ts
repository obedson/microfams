import { jest } from '@jest/globals';
import { walletController } from '../controllers/walletController.js';
import { walletService } from '../services/walletService.js';

jest.mock('../services/walletService.js', () => ({
  walletService: {
    previewWithdrawal: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
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
});
