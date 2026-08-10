import { SavingsController } from '../controllers/savingsController.js';
import { SavingsProductService } from '../domains/financial/savingsProductService.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const productId = '00000000-0000-4000-8000-000000000103';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
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
}) as unknown as jest.Mocked<SavingsProductService>;

describe('savings API contract', () => {
  it('rejects legacy major-unit or floating-point product amounts', async () => {
    const domain = service();
    const controller = new SavingsController(domain);
    const res = response();
    await controller.createProduct({
      tenant: { id: organizationId }, user: { id: actorId },
      body: { code: 'SAV.TEST', name: 'Test', currency: 'NGN', minimumContribution: 100, maximumContributionMinor: 1000 },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.createProduct).not.toHaveBeenCalled();
  });

  it('passes the authenticated tenant and disclosure-bound enrolment', async () => {
    const domain = service();
    domain.enrol.mockResolvedValue({ id: 'enrolment-1' } as never);
    const controller = new SavingsController(domain);
    const res = response();
    const body = {
      targetMinor: 1000000,
      disclosureVersion: '2026.1',
      disclosureContentHash: 'b'.repeat(64),
      idempotencyKey: 'savings-enrolment-api-1',
    };
    await controller.enrol({
      tenant: { id: organizationId }, user: { id: actorId }, params: { productId }, body,
    } as any, res);

    expect(domain.enrol).toHaveBeenCalledWith({ ...body, organizationId, actorId, productId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('does not expose database details when a state transition is rejected', async () => {
    const domain = service();
    domain.approveProduct.mockRejectedValue(new Error('sensitive database detail') as never);
    const controller = new SavingsController(domain);
    const res = response();
    await controller.approveProduct({
      tenant: { id: organizationId }, user: { id: actorId }, params: { productId },
      body: { expectedVersion: 1, idempotencyKey: 'savings-approval-api-1' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'SAVINGS_COMMAND_REJECTED',
      message: expect.not.stringContaining('sensitive'),
    }));
  });

  it('binds a manual contribution to tenant, member, enrolment, and correlation ID', async () => {
    const domain = service();
    domain.contribute.mockResolvedValue({ id: 'contribution-1' } as never);
    const controller = new SavingsController(domain);
    const res = response();
    const correlationId = '00000000-0000-4000-8000-000000000104';
    const body = { amountMinor: 25000, idempotencyKey: 'savings-contribution-api-1' };
    await controller.contribute({
      tenant: { id: organizationId }, user: { id: actorId }, params: { enrolmentId: productId },
      headers: { 'x-correlation-id': correlationId }, body,
    } as any, res);
    expect(domain.contribute).toHaveBeenCalledWith({
      ...body, organizationId, actorId, enrolmentId: productId, correlationId,
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects malformed standing-order times before domain execution', async () => {
    const domain = service();
    const controller = new SavingsController(domain);
    const res = response();
    await controller.createStandingOrder({
      tenant: { id: organizationId }, user: { id: actorId }, params: { enrolmentId: productId },
      body: { amountMinor: 25000, firstDueAt: 'tomorrow', disclosureVersion: '2026.1',
        disclosureContentHash: 'a'.repeat(64), idempotencyKey: 'savings-standing-api-1' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.createStandingOrder).not.toHaveBeenCalled();
  });

  it('binds an accrual calculation to the authenticated tenant and correlation ID', async () => {
    const domain = service();
    domain.calculateAccrual.mockResolvedValue({ id: productId } as never);
    const controller = new SavingsController(domain);
    const res = response();
    const correlationId = '00000000-0000-4000-8000-000000000105';
    const body = {
      productVersionId: productId,
      periodStart: '2026-07-01',
      periodEnd: '2026-08-01',
      idempotencyKey: 'savings-accrual-api-1',
    };
    await controller.calculateAccrual({
      tenant: { id: organizationId }, user: { id: actorId }, headers: { 'x-correlation-id': correlationId }, body,
    } as any, res);
    expect(domain.calculateAccrual).toHaveBeenCalledWith({ ...body, organizationId, actorId, correlationId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires meaningful rejection evidence before accrual review', async () => {
    const domain = service();
    const controller = new SavingsController(domain);
    const res = response();
    await controller.rejectAccrual({
      tenant: { id: organizationId }, user: { id: actorId }, params: { batchId: productId }, headers: {},
      body: { reason: 'short', idempotencyKey: 'savings-accrual-reject-api-1' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.reviewAccrual).not.toHaveBeenCalled();
  });
});
