import { jest } from '@jest/globals';
import {
  addBookingDisputeEvidence,
  getBookingDisputeTimeline,
  openBookingDispute,
} from '../controllers/bookingDisputeController.js';
import {
  BookingDisputeError,
  bookingDisputeService,
} from '../services/bookingDisputeService.js';

jest.mock('../services/bookingDisputeService.js', () => {
  class MockBookingDisputeError extends Error {
    constructor(readonly code: string, readonly status: number) {
      super(code);
    }
  }
  return {
    BookingDisputeError: MockBookingDisputeError,
    bookingDisputeService: {
      open: jest.fn(),
      addEvidence: jest.fn(),
      readTimeline: jest.fn(),
    },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const bookingId = '00000000-0000-4000-8000-000000000401';
const disputeId = '00000000-0000-4000-8000-000000000402';
const organizationId = '00000000-0000-4000-8000-000000000403';
const actorId = '00000000-0000-4000-8000-000000000404';
const correlationId = '00000000-0000-4000-8000-000000000405';

describe('booking dispute API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('opens a dispute using only authenticated tenant and actor identity', async () => {
    (bookingDisputeService.open as jest.Mock).mockResolvedValue({ dispute_id: disputeId } as never);
    const res = response();
    await openBookingDispute({
      params: { id: bookingId },
      headers: {
        'idempotency-key': 'dispute-open-001',
        'x-correlation-id': correlationId,
      },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        reason_code: 'unsafe_facilities',
        narrative: 'The facilities were unsafe and could not be used.',
        requested_remedy: 'refund',
        contested_amount_minor: 40_000,
        organization_id: 'attacker',
        actor_id: 'attacker',
      },
    } as any, res);
    expect(bookingDisputeService.open).toHaveBeenCalledWith({
      bookingId,
      organizationId,
      actorId,
      reasonCode: 'unsafe_facilities',
      narrative: 'The facilities were unsafe and could not be used.',
      requestedRemedy: 'refund',
      contestedAmountMinor: 40_000,
      idempotencyKey: 'dispute-open-001',
      correlationId,
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects short other narratives before persistence', async () => {
    const res = response();
    await openBookingDispute({
      params: { id: bookingId },
      headers: { 'idempotency-key': 'dispute-open-002' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        reason_code: 'other',
        narrative: 'Not enough detail for this reason.',
        requested_remedy: 'refund',
        contested_amount_minor: 10_000,
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingDisputeService.open).not.toHaveBeenCalled();
  });

  it('accepts append-only text evidence without storage identifiers', async () => {
    (bookingDisputeService.addEvidence as jest.Mock)
      .mockResolvedValue({ evidence_id: bookingId } as never);
    const res = response();
    await addBookingDisputeEvidence({
      params: { disputeId },
      headers: {
        'idempotency-key': 'evidence-add-001',
        'x-correlation-id': correlationId,
      },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        evidence_type: 'statement',
        body: 'Access was denied at the agreed arrival time.',
        visibility: 'both',
      },
    } as any, res);
    expect(bookingDisputeService.addEvidence).toHaveBeenCalledWith(
      expect.objectContaining({
        disputeId,
        organizationId,
        actorId,
        storageObjectKey: null,
        malwareScanStatus: 'not_applicable',
      }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires a digest and malware status for file evidence', async () => {
    const res = response();
    await addBookingDisputeEvidence({
      params: { disputeId },
      headers: { 'idempotency-key': 'evidence-add-002' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        evidence_type: 'photo',
        storage_object_key: 'tenant/evidence/photo.jpg',
        media_type: 'image/jpeg',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingDisputeService.addEvidence).not.toHaveBeenCalled();
  });

  it('reads a tenant-scoped sanitized timeline', async () => {
    (bookingDisputeService.readTimeline as jest.Mock)
      .mockResolvedValue({ booking_id: bookingId, disputes: [] } as never);
    const res = response();
    await getBookingDisputeTimeline({
      params: { id: bookingId },
      tenant: { id: organizationId },
      user: { id: actorId },
    } as any, res);
    expect(bookingDisputeService.readTimeline)
      .toHaveBeenCalledWith(bookingId, organizationId, actorId);
  });

  it('returns stable errors without exposing persistence details', async () => {
    (bookingDisputeService.open as jest.Mock).mockRejectedValue(
      new BookingDisputeError('BOOKING_DISPUTE_WINDOW_CLOSED', 409) as never,
    );
    const res = response();
    await openBookingDispute({
      params: { id: bookingId },
      headers: { 'idempotency-key': 'dispute-open-003' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        reason_code: 'supplier_no_show',
        narrative: 'The supplier did not arrive at the agreed time.',
        requested_remedy: 'refund',
        contested_amount_minor: 10_000,
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'BOOKING_DISPUTE_WINDOW_CLOSED',
    });
  });
});
