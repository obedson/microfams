import { jest } from '@jest/globals';
import { groupContributionController } from '../controllers/groupContributionController.js';
import { groupContributionService } from '../services/groupContributionService.js';

jest.mock('../services/groupContributionService.js', () => ({
  groupContributionService: {
    executeRuleProposal: jest.fn(),
    initializePayment: jest.fn(),
    allocatePayment: jest.fn(),
    listProducts: jest.fn(),
    getProduct: jest.fn(),
    listAllocations: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const organizationId = '00000000-0000-4000-8000-000000000301';
const groupId = '00000000-0000-4000-8000-000000000302';
const actorId = '00000000-0000-4000-8000-000000000303';
const memberId = '00000000-0000-4000-8000-000000000304';
const productId = '00000000-0000-4000-8000-000000000305';
const proposalId = '00000000-0000-4000-8000-000000000306';
const paymentId = '00000000-0000-4000-8000-000000000307';

const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId, email: 'member@example.test' },
  params: { id: groupId },
  body: {},
  query: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'contribution-command-001' : undefined,
  ...overrides,
});

describe('group contribution API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('executes an approved contribution rule proposal in resolved tenant context', async () => {
    (groupContributionService.executeRuleProposal as jest.Mock)
      .mockResolvedValue({ id: proposalId } as never);
    const res = response();
    await groupContributionController.executeRuleProposal(request({
      params: { id: groupId, proposalId },
      body: { expectedVersion: 2, organizationId: 'attacker', actorId: 'attacker' },
    }) as any, res);
    expect(groupContributionService.executeRuleProposal).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, proposalId,
      { expectedVersion: 2, idempotencyKey: 'contribution-command-001' },
    );
  });

  it('requires idempotency before an allocation reaches persistence', async () => {
    const res = response();
    await groupContributionController.allocatePayment(request({
      params: { id: groupId, productId },
      body: { memberId, paymentId },
      header: () => undefined,
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionService.allocatePayment).not.toHaveBeenCalled();
  });

  it('never takes the payer or amount currency from the request body', async () => {
    (groupContributionService.initializePayment as jest.Mock)
      .mockResolvedValue({ paymentId } as never);
    const res = response();
    await groupContributionController.initializePayment(request({
      params: { id: groupId, productId },
      body: { amountMinor: 500, payerId: 'attacker', currency: 'USD' },
    }) as any, res);
    expect(groupContributionService.initializePayment).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, productId,
      {
        amountMinor: 500,
        email: 'member@example.test',
        idempotencyKey: 'contribution-command-001',
      },
    );
    expect(res.status).toHaveBeenCalledWith(202);
  });

  it('rejects a malformed product id before reaching the service', async () => {
    const res = response();
    await groupContributionController.getProduct(request({
      params: { id: groupId, productId: 'not-a-uuid' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith({
      error: 'GROUP_CONTRIBUTION_PRODUCT_ID_INVALID',
    });
    expect(groupContributionService.getProduct).not.toHaveBeenCalled();
  });

  it('returns neutral not-found when the caller may not read the product', async () => {
    (groupContributionService.getProduct as jest.Mock).mockResolvedValue(null as never);
    const res = response();
    await groupContributionController.getProduct(request({
      params: { id: groupId, productId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
  });

  it('maps an unverified payment to 409 rather than reporting success', async () => {
    (groupContributionService.allocatePayment as jest.Mock)
      .mockRejectedValue(new Error('GROUP_CONTRIBUTION_PAYMENT_UNVERIFIED') as never);
    const res = response();
    await groupContributionController.allocatePayment(request({
      params: { id: groupId, productId },
      body: { memberId, paymentId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith({
      error: 'GROUP_CONTRIBUTION_PAYMENT_UNVERIFIED',
    });
  });

  it('maps an unsupported rule currency to 400', async () => {
    (groupContributionService.initializePayment as jest.Mock)
      .mockRejectedValue(new Error('GROUP_CONTRIBUTION_CURRENCY_UNSUPPORTED') as never);
    const res = response();
    await groupContributionController.initializePayment(request({
      params: { id: groupId, productId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
  });

  it('bounds the allocation page size', async () => {
    (groupContributionService.listAllocations as jest.Mock)
      .mockResolvedValue({ allocations: [] } as never);
    const res = response();
    await groupContributionController.listAllocations(request({
      params: { id: groupId, productId }, query: { limit: '5000' },
    }) as any, res);
    expect(groupContributionService.listAllocations)
      .toHaveBeenCalledWith({ organizationId, groupId, actorId }, productId, 100);
  });
});
