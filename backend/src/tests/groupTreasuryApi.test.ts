import { jest } from '@jest/globals';
import { groupTreasuryController } from '../controllers/groupTreasuryController.js';
import treasuryService from '../services/groupTreasuryDisbursementService.js';

jest.mock('../services/groupTreasuryDisbursementService.js', () => ({
  __esModule: true,
  default: {
    getAvailableMinor: jest.fn(),
    listBudgets: jest.fn(),
    activateBudget: jest.fn(),
    requestDisbursement: jest.fn(),
    approveDisbursement: jest.fn(),
    executeDisbursement: jest.fn(),
    releaseReservation: jest.fn(),
    reverseDisbursement: jest.fn(),
    listDisbursements: jest.fn(),
    getDisbursement: jest.fn(),
    listReservations: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const organizationId = '00000000-0000-4000-8000-000000000501';
const groupId = '00000000-0000-4000-8000-000000000502';
const actorId = '00000000-0000-4000-8000-000000000503';
const budgetId = '00000000-0000-4000-8000-000000000504';
const proposalId = '00000000-0000-4000-8000-000000000505';
const memberId = '00000000-0000-4000-8000-000000000506';
const disbursementId = '00000000-0000-4000-8000-000000000507';

const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId, email: 'treasurer@example.test' },
  params: { id: groupId },
  body: {},
  query: {},
  header: (name: string) =>
    name === 'Idempotency-Key' ? 'treasury-command-001' : undefined,
  ...overrides,
});

const requestBody = {
  budgetId,
  proposalId,
  beneficiaryKind: 'member',
  beneficiaryMemberId: memberId,
  amountMinor: 120_000,
  currency: 'NGN',
  purpose: 'Reimburse approved operating expenses',
  evidenceUri: 'https://evidence.example.test/receipt-1',
  executeFrom: '2026-08-10T00:00:00.000Z',
  executeUntil: '2026-08-17T00:00:00.000Z',
};

const service = treasuryService as unknown as Record<string, jest.Mock>;

describe('group treasury API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('requests a disbursement in resolved tenant context, ignoring body identity', async () => {
    service.requestDisbursement.mockResolvedValue({ disbursementId } as never);
    const res = response();
    await groupTreasuryController.requestDisbursement(request({
      body: { ...requestBody, organizationId: 'attacker', actorId: 'attacker' },
    }) as any, res);

    expect(service.requestDisbursement).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ budgetId, proposalId, amountMinor: 120_000 }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('refuses an execution window that closes before it opens', async () => {
    const res = response();
    await groupTreasuryController.requestDisbursement(request({
      body: { ...requestBody, executeUntil: '2026-08-01T00:00:00.000Z' },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.requestDisbursement).not.toHaveBeenCalled();
  });

  it('requires evidence before a spend request reaches persistence', async () => {
    const res = response();
    const { evidenceUri, ...withoutEvidence } = requestBody;
    await groupTreasuryController.requestDisbursement(
      request({ body: withoutEvidence }) as any, res,
    );

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.requestDisbursement).not.toHaveBeenCalled();
  });

  it('requires idempotency before an approval reaches persistence', async () => {
    const res = response();
    await groupTreasuryController.approveDisbursement(request({
      params: { id: groupId, disbursementId },
      header: () => undefined,
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.approveDisbursement).not.toHaveBeenCalled();
  });

  it('maps a self-approval refusal to 409 rather than reporting success', async () => {
    service.approveDisbursement.mockRejectedValue(
      new Error('GROUP_TREASURY_SELF_APPROVAL_FORBIDDEN') as never,
    );
    const res = response();
    await groupTreasuryController.approveDisbursement(request({
      params: { id: groupId, disbursementId },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith({
      error: 'GROUP_TREASURY_SELF_APPROVAL_FORBIDDEN',
    });
  });

  it('maps insufficient funds to 409', async () => {
    service.requestDisbursement.mockRejectedValue(
      new Error('GROUP_TREASURY_INSUFFICIENT_AVAILABLE_FUNDS') as never,
    );
    const res = response();
    await groupTreasuryController.requestDisbursement(
      request({ body: requestBody }) as any, res,
    );

    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('maps an unapproved execution to 409', async () => {
    service.executeDisbursement.mockRejectedValue(
      new Error('GROUP_TREASURY_DISBURSEMENT_NOT_APPROVED') as never,
    );
    const res = response();
    await groupTreasuryController.executeDisbursement(request({
      params: { id: groupId, disbursementId },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('requires an uppercase reason code to release a reservation', async () => {
    const res = response();
    await groupTreasuryController.releaseReservation(request({
      params: { id: groupId, disbursementId },
      body: { reasonCode: 'abandoned' },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.releaseReservation).not.toHaveBeenCalled();
  });

  it('passes a valid release through with its reason', async () => {
    service.releaseReservation.mockResolvedValue({ released: true } as never);
    const res = response();
    await groupTreasuryController.releaseReservation(request({
      params: { id: groupId, disbursementId },
      body: { reasonCode: 'ABANDONED' },
    }) as any, res);

    expect(service.releaseReservation).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, disbursementId,
      expect.objectContaining({ reasonCode: 'ABANDONED' }),
    );
  });

  it('rejects a malformed disbursement id before reaching the service', async () => {
    const res = response();
    await groupTreasuryController.getDisbursement(request({
      params: { id: groupId, disbursementId: 'not-a-uuid' },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.getDisbursement).not.toHaveBeenCalled();
  });

  it('returns neutral not-found for a missing disbursement', async () => {
    service.getDisbursement.mockResolvedValue(null as never);
    const res = response();
    await groupTreasuryController.getDisbursement(request({
      params: { id: groupId, disbursementId },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(404);
  });

  it('rejects an unknown state filter when listing', async () => {
    const res = response();
    await groupTreasuryController.listDisbursements(request({
      query: { state: 'settled' },
    }) as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.listDisbursements).not.toHaveBeenCalled();
  });

  it('reports available funds from the engine rather than a cached figure', async () => {
    service.getAvailableMinor.mockResolvedValue(380_000 as never);
    const res = response();
    await groupTreasuryController.getAvailable(request() as any, res);

    expect(service.getAvailableMinor)
      .toHaveBeenCalledWith({ organizationId, groupId, actorId });
    expect(res.json).toHaveBeenCalledWith({
      success: true, data: { availableMinor: 380_000 },
    });
  });
});
