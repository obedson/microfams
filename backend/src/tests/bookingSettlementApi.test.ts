import { jest } from '@jest/globals';
import {
  decideBookingFinancialRule,
  getBookingSettlement,
  proposeBookingFeeRule,
  releaseBookingSettlement,
} from '../controllers/bookingSettlementController.js';
import {
  BookingSettlementError,
  bookingSettlementService,
} from '../services/bookingSettlementService.js';

jest.mock('../services/bookingSettlementService.js', () => {
  class MockBookingSettlementError extends Error {
    constructor(readonly code: string, readonly status: number) {
      super(code);
    }
  }
  return {
    BookingSettlementError: MockBookingSettlementError,
    bookingSettlementService: {
      read: jest.fn(),
      readRules: jest.fn(),
      proposeSettlementRule: jest.fn(),
      proposeFeeRule: jest.fn(),
      decideRule: jest.fn(),
      release: jest.fn(),
    },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const bookingId = '00000000-0000-4000-8000-000000000301';
const organizationId = '00000000-0000-4000-8000-000000000302';
const actorId = '00000000-0000-4000-8000-000000000303';
const correlationId = '00000000-0000-4000-8000-000000000304';

describe('booking settlement API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('reads a tenant-scoped, perspective-safe settlement statement', async () => {
    const statement = {
      perspective: 'customer',
      settlement_state: 'eligible',
      statement: {
        paid_amount_minor: 100_000,
        refundable_amount_minor: 75_000,
        refunded_amount_minor: 10_000,
        contested_amount_minor: 15_000,
        released_amount_minor: 0,
        refund_state: 'succeeded',
        dispute_state: 'under_review',
      },
      finance_statement: null,
    };
    (bookingSettlementService.read as jest.Mock).mockResolvedValue(statement as never);
    const res = response();
    await getBookingSettlement({
      params: { id: bookingId },
      tenant: { id: organizationId },
      user: { id: actorId },
    } as any, res);
    expect(bookingSettlementService.read).toHaveBeenCalledWith(bookingId, organizationId, actorId);
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: statement,
    });
  });

  it('requires bounded idempotency and derives tenant and actor identity', async () => {
    const res = response();
    await releaseBookingSettlement({
      params: { id: bookingId },
      headers: { 'idempotency-key': 'release-001', 'x-correlation-id': correlationId },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: { organizationId: 'attacker', actorId: 'attacker' },
    } as any, res);
    expect(bookingSettlementService.release).toHaveBeenCalledWith({
      bookingId,
      organizationId,
      actorId,
      idempotencyKey: 'release-001',
      correlationId,
    });
  });

  it('proposes normalized fee rules under the authenticated tenant', async () => {
    (bookingSettlementService.proposeFeeRule as jest.Mock)
      .mockResolvedValue({ approval_id: correlationId } as never);
    const res = response();
    await proposeBookingFeeRule({
      headers: { 'idempotency-key': 'fee-rule-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        version: 2,
        currency: 'ngn',
        payer: 'supplier',
        beneficiary_organization_id: bookingId,
        fixed_amount_minor: 100,
        basis_points: 250,
        minimum_amount_minor: 0,
        maximum_amount_minor: null,
        tax_withholding_metadata: { tax_code: 'NONE' },
        effective_from: '2026-08-01T00:00:00.000Z',
        change_reason: 'Approved supplier-funded fee proposal.',
        actor_id: 'attacker',
      },
    } as any, res);
    expect(bookingSettlementService.proposeFeeRule).toHaveBeenCalledWith(
      expect.objectContaining({
        organizationId,
        actorId,
        currency: 'NGN',
        idempotencyKey: 'fee-rule-001',
      }),
    );
    expect(res.status).toHaveBeenCalledWith(202);
  });

  it('passes rule decisions under the authenticated checker identity', async () => {
    (bookingSettlementService.decideRule as jest.Mock)
      .mockResolvedValue({ state: 'approved' } as never);
    const res = response();
    await decideBookingFinancialRule({
      params: { approvalId: correlationId },
      headers: { 'idempotency-key': 'rule-decision-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        approve: true,
        reason: 'Independent review completed and approved.',
        actor_id: 'attacker',
      },
    } as any, res);
    expect(bookingSettlementService.decideRule).toHaveBeenCalledWith({
      approvalId: correlationId,
      organizationId,
      actorId,
      approve: true,
      reason: 'Independent review completed and approved.',
      idempotencyKey: 'rule-decision-001',
    });
  });

  it('returns stable conflict codes without exposing persistence messages', async () => {
    (bookingSettlementService.release as jest.Mock).mockRejectedValue(
      new BookingSettlementError('BOOKING_SETTLEMENT_ACTIVE_HOLD', 409) as never,
    );
    const res = response();
    await releaseBookingSettlement({
      params: { id: bookingId },
      headers: { 'idempotency-key': 'release-002' },
      tenant: { id: organizationId },
      user: { id: actorId },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'BOOKING_SETTLEMENT_ACTIVE_HOLD',
    });
  });

  it('rejects invalid booking identifiers before reaching the service', async () => {
    const res = response();
    await getBookingSettlement({
      params: { id: 'not-a-booking' },
      tenant: { id: organizationId },
      user: { id: actorId },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingSettlementService.read).not.toHaveBeenCalled();
  });
});
