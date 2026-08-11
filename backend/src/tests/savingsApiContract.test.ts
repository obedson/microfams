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
  requestWithdrawal: jest.fn(),
  reviewWithdrawal: jest.fn(),
  cancelWithdrawal: jest.fn(),
  listWithdrawals: jest.fn(),
  listWithdrawalReviews: jest.fn(),
  getStatement: jest.fn(),
  getReconciliation: jest.fn(),
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

  it('binds withdrawal requests to the authenticated tenant, member, and correlation ID', async () => {
    const domain = service();
    domain.requestWithdrawal.mockResolvedValue({ id: productId, state: 'pending_approval' } as never);
    const controller = new SavingsController(domain);
    const res = response();
    const correlationId = '00000000-0000-4000-8000-000000000106';
    const body = { amountMinor: 50000, idempotencyKey: 'savings-withdrawal-api-1' };

    await controller.requestWithdrawal({
      tenant: { id: organizationId }, user: { id: actorId }, params: { enrolmentId: productId },
      headers: { 'x-correlation-id': correlationId }, body,
    } as any, res);

    expect(domain.requestWithdrawal).toHaveBeenCalledWith({
      ...body, organizationId, actorId, enrolmentId: productId, correlationId,
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires meaningful evidence for withdrawal rejection and cancellation', async () => {
    const domain = service();
    const controller = new SavingsController(domain);
    const rejection = response();
    const cancellation = response();
    const command = { reason: 'short', idempotencyKey: 'savings-withdrawal-decision-api-1' };

    await controller.rejectWithdrawal({
      tenant: { id: organizationId }, user: { id: actorId }, params: { withdrawalId: productId },
      headers: {}, body: command,
    } as any, rejection);
    await controller.cancelWithdrawal({
      tenant: { id: organizationId }, user: { id: actorId }, params: { withdrawalId: productId },
      headers: {}, body: command,
    } as any, cancellation);

    expect(rejection.status).toHaveBeenCalledWith(400);
    expect(cancellation.status).toHaveBeenCalledWith(400);
    expect(domain.reviewWithdrawal).not.toHaveBeenCalled();
    expect(domain.cancelWithdrawal).not.toHaveBeenCalled();
  });

  it('binds statement reads to the authenticated tenant, actor, and enrolment', async () => {
    const domain = service();
    domain.getStatement.mockResolvedValue({ entries: [] } as never);
    const controller = new SavingsController(domain);
    const res = response();

    await controller.getStatement({
      tenant: { id: organizationId }, user: { id: actorId }, params: { enrolmentId: productId },
      query: { from: '2026-08-01', to: '2026-08-11', page: '2', limit: '20' },
    } as any, res);

    expect(domain.getStatement).toHaveBeenCalledWith({
      organizationId, actorId, enrolmentId: productId,
      from: '2026-08-01', to: '2026-08-11', page: 2, limit: 20,
    });
    expect(res.json).toHaveBeenCalledWith({ statement: { entries: [] } });
  });

  it('rejects malformed statement queries before domain execution', async () => {
    const domain = service();
    const controller = new SavingsController(domain);
    const res = response();

    await controller.getStatement({
      tenant: { id: organizationId }, user: { id: actorId }, params: { enrolmentId: productId },
      query: { from: '11 August 2026', limit: '101' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.getStatement).not.toHaveBeenCalled();
  });

  it('binds reconciliation controls to the authenticated tenant and finance actor', async () => {
    const domain = service();
    domain.getReconciliation.mockResolvedValue({ summary: { matchedCount: 4 } } as never);
    const controller = new SavingsController(domain);
    const res = response();

    await controller.getReconciliation({
      tenant: { id: organizationId }, user: { id: actorId },
      query: { currency: 'NGN', staleAfterHours: '48', page: '1', limit: '50' },
    } as any, res);

    expect(domain.getReconciliation).toHaveBeenCalledWith({
      organizationId, actorId, currency: 'NGN', staleAfterHours: 48, page: 1, limit: 50,
    });
    expect(res.json).toHaveBeenCalledWith({ reconciliation: { summary: { matchedCount: 4 } } });
  });
});
