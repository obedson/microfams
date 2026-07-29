import { jest } from '@jest/globals';
import {
  decideBookingDisputeResolution,
  proposeBookingDisputeResolution,
  transitionBookingDispute,
} from '../controllers/bookingDisputeResolutionController.js';
import {
  BookingDisputeResolutionError,
  bookingDisputeResolutionService,
} from '../services/bookingDisputeResolutionService.js';

jest.mock('../services/bookingDisputeResolutionService.js', () => {
  class MockError extends Error {
    constructor(readonly code: string, readonly status: number) { super(code); }
  }
  return {
    BookingDisputeResolutionError: MockError,
    bookingDisputeResolutionService: {
      transition: jest.fn(),
      propose: jest.fn(),
      decide: jest.fn(),
      readCase: jest.fn(),
      proposeResponseRule: jest.fn(),
      decideResponseRule: jest.fn(),
    },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};
const disputeId = '00000000-0000-4000-8000-000000000501';
const proposalId = '00000000-0000-4000-8000-000000000502';
const organizationId = '00000000-0000-4000-8000-000000000503';
const actorId = '00000000-0000-4000-8000-000000000504';
const correlationId = '00000000-0000-4000-8000-000000000505';

describe('booking dispute resolution API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('transitions using authenticated tenant and actor identity', async () => {
    (bookingDisputeResolutionService.transition as jest.Mock)
      .mockResolvedValue({ state: 'under_review' } as never);
    const res = response();
    await transitionBookingDispute({
      params: { disputeId },
      headers: {
        'idempotency-key': 'resolution-transition-001',
        'x-correlation-id': correlationId,
      },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        target_state: 'under_review',
        reason: 'Evidence collection is complete and review may begin.',
        actor_id: 'attacker',
      },
    } as any, res);
    expect(bookingDisputeResolutionService.transition).toHaveBeenCalledWith({
      disputeId,
      organizationId,
      actorId,
      targetState: 'under_review',
      reason: 'Evidence collection is complete and review may begin.',
      idempotencyKey: 'resolution-transition-001',
      correlationId,
    });
  });

  it('rejects a non-conserved proposal before persistence', async () => {
    const res = response();
    await proposeBookingDisputeResolution({
      params: { disputeId },
      headers: { 'idempotency-key': 'resolution-proposal-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        contested_amount_minor: 40_000,
        customer_refund_minor: 15_000,
        supplier_release_minor: 24_999,
        platform_fee_minor: 0,
        recoverable_amount_minor: 0,
        loss_amount_minor: 0,
        evidence_ids: [],
        reason: 'This proposed split intentionally fails exact conservation.',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingDisputeResolutionService.propose).not.toHaveBeenCalled();
  });

  it('submits a conserved proposal without trusting body tenant fields', async () => {
    (bookingDisputeResolutionService.propose as jest.Mock)
      .mockResolvedValue({ proposal_id: proposalId } as never);
    const res = response();
    await proposeBookingDisputeResolution({
      params: { disputeId },
      headers: {
        'idempotency-key': 'resolution-proposal-002',
        'x-correlation-id': correlationId,
      },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        organization_id: 'attacker',
        contested_amount_minor: 40_000,
        customer_refund_minor: 15_000,
        supplier_release_minor: 25_000,
        platform_fee_minor: 0,
        recoverable_amount_minor: 0,
        loss_amount_minor: 0,
        evidence_ids: [],
        reason: 'This conserved split is supported by the reviewed evidence.',
      },
    } as any, res);
    expect(bookingDisputeResolutionService.propose).toHaveBeenCalledWith(
      expect.objectContaining({ disputeId, organizationId, actorId }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps independent-approver failures to a stable response', async () => {
    (bookingDisputeResolutionService.decide as jest.Mock).mockRejectedValue(
      new BookingDisputeResolutionError(
        'BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT',
        403,
      ) as never,
    );
    const res = response();
    await decideBookingDisputeResolution({
      params: { proposalId },
      headers: { 'idempotency-key': 'resolution-decision-001' },
      user: { id: actorId },
      body: {
        approve: true,
        reason: 'Independent review confirms that the proposal is correct.',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT',
    });
  });
});
