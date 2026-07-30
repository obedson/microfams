import { jest } from '@jest/globals';
import {
  cancelBookingSupplierPayout,
  createBookingSupplierPayout,
  decideBookingPayoutBeneficiary,
  proposeBookingPayoutChangeRule,
  registerBookingPayoutBeneficiary,
} from '../controllers/bookingSupplierPayoutController.js';
import {
  bookingSupplierPayoutService,
} from '../services/bookingSupplierPayoutService.js';

jest.mock('../services/bookingSupplierPayoutService.js', () => ({
  BookingSupplierPayoutError: class MockError extends Error {
    constructor(readonly code: string, readonly status: number) { super(code); }
  },
  bookingSupplierPayoutService: {
    registerBeneficiary: jest.fn(),
    decideBeneficiary: jest.fn(),
    listBeneficiaries: jest.fn(),
    proposeChangeRule: jest.fn(),
    decideChangeRule: jest.fn(),
    createAndSubmit: jest.fn(),
    sync: jest.fn(),
    cancel: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};
const organizationId = '00000000-0000-4000-8000-000000000601';
const actorId = '00000000-0000-4000-8000-000000000602';
const beneficiaryId = '00000000-0000-4000-8000-000000000603';
const releaseId = '00000000-0000-4000-8000-000000000604';
const correlationId = '00000000-0000-4000-8000-000000000605';

describe('booking supplier payout API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses tenant identity and never accepts an account name from the caller', async () => {
    (bookingSupplierPayoutService.registerBeneficiary as jest.Mock)
      .mockResolvedValue({ beneficiary_id: beneficiaryId } as never);
    const res = response();
    await registerBookingPayoutBeneficiary({
      headers: { 'idempotency-key': 'beneficiary-register-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        organization_id: 'attacker',
        account_number: '0123456789',
        bank_code: '044',
        account_name: 'Untrusted Name',
      },
    } as any, res);
    expect(bookingSupplierPayoutService.registerBeneficiary)
      .toHaveBeenCalledWith({
        organizationId,
        actorId,
        beneficiaryUserId: null,
        accountNumber: '0123456789',
        bankCode: '044',
        idempotencyKey: 'beneficiary-register-001',
      });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects malformed destination details before verification', async () => {
    const res = response();
    await registerBookingPayoutBeneficiary({
      headers: { 'idempotency-key': 'beneficiary-register-002' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: { account_number: '1234', bank_code: '044' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingSupplierPayoutService.registerBeneficiary)
      .not.toHaveBeenCalled();
  });

  it('submits one release-scoped payout using authenticated identity', async () => {
    (bookingSupplierPayoutService.createAndSubmit as jest.Mock)
      .mockResolvedValue({ state: 'processing' } as never);
    const res = response();
    await createBookingSupplierPayout({
      params: { releaseId },
      headers: {
        'idempotency-key': 'booking-payout-create-001',
        'x-correlation-id': correlationId,
      },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: { beneficiary_id: beneficiaryId, amount_minor: 999_999 },
    } as any, res);
    expect(bookingSupplierPayoutService.createAndSubmit).toHaveBeenCalledWith({
      settlementReleaseId: releaseId,
      organizationId,
      actorId,
      beneficiaryId,
      idempotencyKey: 'booking-payout-create-001',
      correlationId,
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires an explicit independent-decision contract', async () => {
    const res = response();
    await decideBookingPayoutBeneficiary({
      params: { beneficiaryId },
      headers: { 'idempotency-key': 'beneficiary-decision-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: { approve: 'yes', reason: 'Invalid boolean decision.' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingSupplierPayoutService.decideBeneficiary)
      .not.toHaveBeenCalled();
  });

  it('validates change-control rules before proposing them', async () => {
    const res = response();
    await proposeBookingPayoutChangeRule({
      headers: { 'idempotency-key': 'payout-rule-proposal-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        version: 2,
        change_window_hours: 200,
        effective_from: new Date().toISOString(),
        change_reason: 'Outside the approved maximum.',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingSupplierPayoutService.proposeChangeRule)
      .not.toHaveBeenCalled();
  });

  it('cancels only through the tenant-scoped servicing command', async () => {
    (bookingSupplierPayoutService.cancel as jest.Mock)
      .mockResolvedValue({ state: 'cancelled' } as never);
    const res = response();
    await cancelBookingSupplierPayout({
      params: { payoutId: releaseId },
      headers: { 'idempotency-key': 'booking-payout-cancel-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        organization_id: 'attacker',
        reason: 'Operator cancelled before provider submission.',
      },
    } as any, res);
    expect(bookingSupplierPayoutService.cancel).toHaveBeenCalledWith({
      payoutId: releaseId,
      organizationId,
      actorId,
      reason: 'Operator cancelled before provider submission.',
      idempotencyKey: 'booking-payout-cancel-001',
    });
    expect(res.status).not.toHaveBeenCalled();
  });
});
