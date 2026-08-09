import { SavingsGateway, SavingsProductService } from '../domains/financial/savingsProductService.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const productId = '00000000-0000-4000-8000-000000000103';
const disclosureContentHash = 'a'.repeat(64);

const gateway = (): jest.Mocked<SavingsGateway> => ({
  createProduct: jest.fn(),
  submitProduct: jest.fn(),
  approveProduct: jest.fn(),
  enrol: jest.fn(),
  listProducts: jest.fn(),
  listEnrolments: jest.fn(),
});

const productCommand = {
  organizationId,
  actorId,
  code: 'SAV.HARVEST',
  name: 'Harvest goal',
  currency: 'NGN',
  minimumContributionMinor: 10000,
  maximumContributionMinor: 50000000,
  contributionFrequency: 'monthly' as const,
  defaultTargetMinor: 1000000,
  lockPeriodDays: 90,
  gracePeriodDays: 7,
  earlyWithdrawalRule: 'forfeit_returns' as const,
  earlyWithdrawalFeeMinor: 0,
  returnMethod: 'simple_interest' as const,
  annualRateBasisPoints: 750,
  dayCountConvention: 'actual_365' as const,
  disclosureVersion: '2026.1',
  disclosureContentHash,
  eligibility: { minimumKycTier: 1 },
  idempotencyKey: 'savings-product-command-1',
};

describe('SavingsProductService', () => {
  it('passes integer-minor-unit and disclosure facts to the product gateway', async () => {
    const storage = gateway();
    storage.createProduct.mockResolvedValue({ product: { id: productId } });
    const service = new SavingsProductService(storage);

    await expect(service.createProduct(productCommand)).resolves.toEqual({ product: { id: productId } });
    expect(storage.createProduct).toHaveBeenCalledWith(productCommand);
  });

  it('rejects inconsistent return and early-withdrawal rules before storage access', async () => {
    const storage = gateway();
    const service = new SavingsProductService(storage);

    expect(() => service.createProduct({
      ...productCommand,
      returnMethod: 'none',
      annualRateBasisPoints: 750,
    })).toThrow('Return method');
    expect(() => service.createProduct({
      ...productCommand,
      earlyWithdrawalRule: 'fee',
      earlyWithdrawalFeeMinor: 0,
    })).toThrow('Early-withdrawal fee');
    expect(storage.createProduct).not.toHaveBeenCalled();
  });

  it('binds enrolment to the exact accepted disclosure', async () => {
    const storage = gateway();
    storage.enrol.mockResolvedValue({ id: 'enrolment-1' });
    const service = new SavingsProductService(storage);
    const command = {
      organizationId,
      actorId,
      productId,
      targetMinor: 2000000,
      disclosureVersion: '2026.1',
      disclosureContentHash,
      idempotencyKey: 'savings-enrolment-command-1',
    };

    await expect(service.enrol(command)).resolves.toEqual({ id: 'enrolment-1' });
    expect(storage.enrol).toHaveBeenCalledWith(command);
  });

  it('rejects floating-point money and malformed disclosure hashes', async () => {
    const storage = gateway();
    const service = new SavingsProductService(storage);

    expect(() => service.enrol({
      organizationId, actorId, productId, targetMinor: 10.5,
      disclosureVersion: '2026.1', disclosureContentHash,
      idempotencyKey: 'savings-enrolment-command-2',
    })).toThrow('minor units');
    expect(() => service.enrol({
      organizationId, actorId, productId,
      disclosureVersion: '2026.1', disclosureContentHash: 'not-a-hash',
      idempotencyKey: 'savings-enrolment-command-3',
    })).toThrow('SHA-256');
    expect(storage.enrol).not.toHaveBeenCalled();
  });

  it('keeps submit and independent approval as separate commands', async () => {
    const storage = gateway();
    storage.submitProduct.mockResolvedValue({ state: 'pending_approval' });
    storage.approveProduct.mockResolvedValue({ state: 'active' });
    const service = new SavingsProductService(storage);
    const command = { organizationId, actorId, productId, expectedVersion: 1, idempotencyKey: 'savings-lifecycle-command-1' };

    await service.submitProduct(command);
    await service.approveProduct({ ...command, idempotencyKey: 'savings-lifecycle-command-2' });

    expect(storage.submitProduct).toHaveBeenCalledTimes(1);
    expect(storage.approveProduct).toHaveBeenCalledTimes(1);
  });
});
