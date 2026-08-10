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
});
