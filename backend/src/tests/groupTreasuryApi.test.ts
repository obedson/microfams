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
    registerBeneficiary: jest.fn(),
    approveBeneficiary: jest.fn(),
    rejectBeneficiary: jest.fn(),
    listBeneficiaries: jest.fn(),
    requestExternalDisbursement: jest.fn(),
    beginExternalDisbursement: jest.fn(),
    syncExternalPayout: jest.fn(),
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
const beneficiaryId = '00000000-0000-4000-8000-000000000508';
const externalBeneficiaryId = '00000000-0000-4000-8000-000000000509';

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

const externalRequestBody = {
  budgetId,
  proposalId,
  externalBeneficiaryId,
  amountMinor: 250_000,
  currency: 'NGN',
  purpose: 'Settle verified supplier invoice',
  evidenceUri: 'https://evidence.example.test/invoice-9',
  executeFrom: '2026-08-10T00:00:00.000Z',
  executeUntil: '2026-08-17T00:00:00.000Z',
};

const beneficiaryBody = {
  beneficiaryUserId: null,
  accountNumber: '0123456789',
  bankCode: '058',
  accountName: 'Verified Supplier Ltd',
  currency: 'NGN',
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

  describe('external provider disbursements', () => {
    it('registers a verified beneficiary in resolved tenant context', async () => {
      service.registerBeneficiary.mockResolvedValue({ id: beneficiaryId } as never);
      const res = response();
      await groupTreasuryController.registerBeneficiary(request({
        body: { ...beneficiaryBody, organizationId: 'attacker' },
      }) as any, res);

      expect(service.registerBeneficiary).toHaveBeenCalledWith(
        { organizationId, groupId, actorId },
        expect.objectContaining({
          accountNumber: '0123456789', bankCode: '058', currency: 'NGN',
          idempotencyKey: 'treasury-command-001',
        }),
      );
      expect(res.status).toHaveBeenCalledWith(201);
    });

    it('refuses a malformed NUBAN before it reaches the service', async () => {
      const res = response();
      await groupTreasuryController.registerBeneficiary(request({
        body: { ...beneficiaryBody, accountNumber: '123' },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(400);
      expect(service.registerBeneficiary).not.toHaveBeenCalled();
    });

    it('requires an approval reason to verify a beneficiary', async () => {
      const res = response();
      await groupTreasuryController.approveBeneficiary(request({
        params: { id: groupId, beneficiaryId },
        body: { approvalReason: 'too short' },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(400);
      expect(service.approveBeneficiary).not.toHaveBeenCalled();
    });

    it('maps a maker-cannot-check beneficiary refusal to 409', async () => {
      service.approveBeneficiary.mockRejectedValue(
        new Error('GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK') as never,
      );
      const res = response();
      await groupTreasuryController.approveBeneficiary(request({
        params: { id: groupId, beneficiaryId },
        body: { approvalReason: 'Confirmed the supplier account by phone.' },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(409);
      expect(res.json).toHaveBeenCalledWith({
        error: 'GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK',
      });
    });

    it('rejects a beneficiary through the checker path', async () => {
      service.rejectBeneficiary.mockResolvedValue({ id: beneficiaryId } as never);
      const res = response();
      await groupTreasuryController.rejectBeneficiary(request({
        params: { id: groupId, beneficiaryId },
      }) as any, res);

      expect(service.rejectBeneficiary).toHaveBeenCalledWith(
        { organizationId, groupId, actorId }, beneficiaryId,
        expect.objectContaining({ idempotencyKey: 'treasury-command-001' }),
      );
    });

    it('rejects an unknown beneficiary state filter when listing', async () => {
      const res = response();
      await groupTreasuryController.listBeneficiaries(request({
        query: { state: 'frozen' },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(400);
      expect(service.listBeneficiaries).not.toHaveBeenCalled();
    });

    it('requests an external disbursement against a verified beneficiary', async () => {
      service.requestExternalDisbursement.mockResolvedValue({ disbursementId } as never);
      const res = response();
      await groupTreasuryController.requestExternalDisbursement(request({
        body: { ...externalRequestBody, actorId: 'attacker' },
      }) as any, res);

      expect(service.requestExternalDisbursement).toHaveBeenCalledWith(
        { organizationId, groupId, actorId },
        expect.objectContaining({
          budgetId, externalBeneficiaryId, amountMinor: 250_000, currency: 'NGN',
        }),
      );
      expect(res.status).toHaveBeenCalledWith(201);
    });

    it('refuses an external request in a currency the adapter cannot settle', async () => {
      const res = response();
      await groupTreasuryController.requestExternalDisbursement(request({
        body: { ...externalRequestBody, currency: 'USD' },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(400);
      expect(service.requestExternalDisbursement).not.toHaveBeenCalled();
    });

    it('begins an approved external disbursement', async () => {
      service.beginExternalDisbursement.mockResolvedValue({
        disbursementId, payout: { state: 'processing' },
      } as never);
      const res = response();
      await groupTreasuryController.beginExternalDisbursement(request({
        params: { id: groupId, disbursementId },
      }) as any, res);

      expect(service.beginExternalDisbursement).toHaveBeenCalledWith(
        { organizationId, groupId, actorId }, disbursementId,
        expect.objectContaining({ idempotencyKey: 'treasury-command-001' }),
      );
    });

    it('maps an unverified beneficiary at begin time to 409', async () => {
      service.beginExternalDisbursement.mockRejectedValue(
        new Error('GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED') as never,
      );
      const res = response();
      await groupTreasuryController.beginExternalDisbursement(request({
        params: { id: groupId, disbursementId },
      }) as any, res);

      expect(res.status).toHaveBeenCalledWith(409);
    });

    it('syncs an in-flight payout without an idempotency key', async () => {
      service.syncExternalPayout.mockResolvedValue({ state: 'succeeded' } as never);
      const res = response();
      await groupTreasuryController.syncExternalPayout(request({
        params: { id: groupId, disbursementId },
        header: () => undefined,
      }) as any, res);

      expect(service.syncExternalPayout).toHaveBeenCalledWith(
        { organizationId, groupId, actorId }, disbursementId,
      );
      expect(res.json).toHaveBeenCalledWith({
        success: true, data: { state: 'succeeded' },
      });
    });
  });
});
