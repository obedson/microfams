import {
  calculateSimpleSavingsAccrualMinor,
  SavingsGateway,
  SavingsProductService,
} from '../domains/financial/savingsProductService.js';

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
  contribute: jest.fn(),
  createStandingOrder: jest.fn(),
  transitionStandingOrder: jest.fn(),
  listContributions: jest.fn(),
  listStandingOrders: jest.fn(),
  calculateAccrual: jest.fn(),
  reviewAccrual: jest.fn(),
  listAccrualBatches: jest.fn(),
  listAccruals: jest.fn(),
  requestWithdrawal: jest.fn(),
  reviewWithdrawal: jest.fn(),
  cancelWithdrawal: jest.fn(),
  listWithdrawals: jest.fn(),
  listWithdrawalReviews: jest.fn(),
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
  it('calculates simple returns with deterministic half-up integer rounding', () => {
    expect(calculateSimpleSavingsAccrualMinor({
      eligiblePrincipalDaysMinor: 3000000n,
      annualRateBasisPoints: 3650,
      dayCountConvention: 'actual_365',
    })).toBe(3000n);
    expect(calculateSimpleSavingsAccrualMinor({
      eligiblePrincipalDaysMinor: 1n,
      annualRateBasisPoints: 5000,
      dayCountConvention: 'actual_360',
    })).toBe(0n);
  });

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

  it('validates accrual periods and independent review commands before storage access', async () => {
    const storage = gateway();
    storage.calculateAccrual.mockResolvedValue({ id: productId });
    storage.reviewAccrual.mockResolvedValue({ id: productId, state: 'posted' });
    const service = new SavingsProductService(storage);
    const calculate = {
      organizationId, actorId, productVersionId: productId,
      periodStart: '2026-07-01', periodEnd: '2026-08-01',
      idempotencyKey: 'savings-accrual-calculate-1',
      correlationId: '00000000-0000-4000-8000-000000000104',
    };
    await expect(service.calculateAccrual(calculate)).resolves.toEqual({ id: productId });
    expect(() => service.calculateAccrual({ ...calculate, periodEnd: '2026-07-01' }))
      .toThrow('must be after');

    await expect(service.reviewAccrual({
      organizationId, actorId, batchId: productId, action: 'approve',
      idempotencyKey: 'savings-accrual-approve-1',
      correlationId: '00000000-0000-4000-8000-000000000105',
    })).resolves.toEqual({ id: productId, state: 'posted' });
    expect(() => service.reviewAccrual({
      organizationId, actorId, batchId: productId, action: 'reject', reason: 'short',
      idempotencyKey: 'savings-accrual-reject-1',
      correlationId: '00000000-0000-4000-8000-000000000106',
    })).toThrow('Rejection reason');
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

  it('validates minor-unit contributions and correlation evidence', async () => {
    const storage = gateway();
    storage.contribute.mockResolvedValue({ id: 'contribution-1' });
    const service = new SavingsProductService(storage);
    const command = {
      organizationId, actorId, enrolmentId: productId, amountMinor: 25000,
      idempotencyKey: 'savings-contribution-command-1',
      correlationId: '00000000-0000-4000-8000-000000000104',
    };
    await expect(service.contribute(command)).resolves.toEqual({ id: 'contribution-1' });
    expect(storage.contribute).toHaveBeenCalledWith(command);
    expect(() => service.contribute({ ...command, amountMinor: 25.5 })).toThrow('minor units');
  });

  it('requires canonical UTC scheduling and disclosure evidence for standing orders', () => {
    const storage = gateway();
    const service = new SavingsProductService(storage);
    const command = {
      organizationId, actorId, enrolmentId: productId, amountMinor: 25000,
      firstDueAt: '2026-09-01T08:00:00.000Z', disclosureVersion: '2026.1',
      disclosureContentHash, idempotencyKey: 'savings-standing-order-command-1',
    };
    service.createStandingOrder(command);
    expect(storage.createStandingOrder).toHaveBeenCalledWith(command);
    expect(() => service.createStandingOrder({ ...command, firstDueAt: 'next month' })).toThrow('ISO-8601');
  });

  it('validates and forwards governed withdrawal requests in minor units', async () => {
    const storage = gateway();
    storage.requestWithdrawal.mockResolvedValue({ id: productId, state: 'pending_approval' });
    const service = new SavingsProductService(storage);
    const command = {
      organizationId, actorId, enrolmentId: productId, amountMinor: 50000,
      idempotencyKey: 'savings-withdrawal-request-1',
      correlationId: '00000000-0000-4000-8000-000000000107',
    };

    await expect(service.requestWithdrawal(command)).resolves.toEqual({ id: productId, state: 'pending_approval' });
    expect(storage.requestWithdrawal).toHaveBeenCalledWith(command);
    expect(() => service.requestWithdrawal({ ...command, amountMinor: 50.5 })).toThrow('minor units');
  });

  it('requires evidence for withdrawal rejection and cancellation', async () => {
    const storage = gateway();
    storage.reviewWithdrawal.mockResolvedValue({ id: productId, state: 'rejected' });
    storage.cancelWithdrawal.mockResolvedValue({ id: productId, state: 'cancelled' });
    const service = new SavingsProductService(storage);
    const base = {
      organizationId, actorId, withdrawalId: productId,
      idempotencyKey: 'savings-withdrawal-review-1',
      correlationId: '00000000-0000-4000-8000-000000000108',
    };

    expect(() => service.reviewWithdrawal({ ...base, action: 'reject', reason: 'short' })).toThrow('Rejection reason');
    expect(() => service.reviewWithdrawal({ ...base, action: 'approve', reason: 'not accepted' })).toThrow('does not accept');
    expect(() => service.cancelWithdrawal({ ...base, reason: 'short' })).toThrow('Cancellation reason');

    await expect(service.reviewWithdrawal({
      ...base, action: 'reject', reason: 'Member requested a corrected amount.',
    })).resolves.toEqual({ id: productId, state: 'rejected' });
    await expect(service.cancelWithdrawal({
      ...base, idempotencyKey: 'savings-withdrawal-cancel-1', reason: 'Member no longer needs the funds.',
    })).resolves.toEqual({ id: productId, state: 'cancelled' });
  });
});
