import { paymentService } from '../domains/financial/paymentService.js';
import { BookingModel } from '../models/Booking.js';
import {
  BookingRefundOrchestrationService,
  validateBookingCancellation,
} from '../services/bookingRefundOrchestrationService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { rpc: jest.fn(), from: jest.fn() } }));
jest.mock('../domains/financial/paymentService.js', () => ({
  paymentService: { submitRefund: jest.fn() },
}));
jest.mock('../models/Booking.js', () => ({
  BookingModel: { findByIdWithDetails: jest.fn() },
}));
jest.mock('../services/emailService.js', () => ({ sendEmail: jest.fn() }));

describe('booking refund orchestration service', () => {
  const request = {
    bookingId: '00000000-0000-4000-8000-000000000201',
    organizationId: '00000000-0000-4000-8000-000000000202',
    cancelledBy: '00000000-0000-4000-8000-000000000203',
    reason: 'Change of plans',
    idempotencyKey: 'booking-cancel-test-001',
    correlationId: '00000000-0000-4000-8000-000000000204',
  };

  beforeEach(() => {
    jest.clearAllMocks();
    (BookingModel.findByIdWithDetails as jest.Mock).mockResolvedValue(null);
  });

  it('uses one atomic command and submits only the stored canonical refund', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({ data: {
      id: 'cancellation-1', organization_id: request.organizationId,
      refund_id: 'refund-1', outcome: 'refund_created',
    }, error: null });
    (paymentService.submitRefund as jest.Mock).mockResolvedValue({ state: 'processing' });

    const result = await BookingRefundOrchestrationService.processCancellation(request);

    expect(supabase.rpc).toHaveBeenCalledWith('cancel_booking_with_refund', expect.objectContaining({
      p_booking_id: request.bookingId,
      p_acting_organization_id: request.organizationId,
      p_idempotency_key: request.idempotencyKey,
    }));
    expect(paymentService.submitRefund).toHaveBeenCalledWith(
      'refund-1', request.organizationId, request.cancelledBy,
    );
    expect(result).toMatchObject({ success: true, refund_status: 'refund_processing' });
  });

  it('keeps cancellation successful when provider submission is unknown', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({ data: {
      id: 'cancellation-1', organization_id: request.organizationId,
      refund_id: 'refund-1', outcome: 'refund_created',
    }, error: null });
    (paymentService.submitRefund as jest.Mock).mockRejectedValue(new Error('provider timeout'));

    await expect(BookingRefundOrchestrationService.processCancellation(request)).resolves.toMatchObject({
      success: true,
      refund_status: 'refund_processing',
    });
  });

  it('maps tenant authorization and idempotency conflicts to explicit outcomes', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValueOnce({
      data: null, error: { message: 'Booking cancellation is not authorized' },
    });
    await expect(BookingRefundOrchestrationService.processCancellation(request)).resolves.toMatchObject({
      success: false, error: 'UNAUTHORIZED',
    });
    (supabase.rpc as jest.Mock).mockResolvedValueOnce({
      data: null, error: { message: 'Cancellation replay changed the original request' },
    });
    await expect(BookingRefundOrchestrationService.processCancellation(request)).resolves.toMatchObject({
      success: false, error: 'IDEMPOTENCY_CONFLICT',
    });
  });

  it('keeps cancellable status policy deterministic', () => {
    expect(validateBookingCancellation({ status: 'confirmed' })).toEqual({ canCancel: true });
    expect(validateBookingCancellation({ status: 'completed' })).toEqual({
      canCancel: false, reason: 'Cannot cancel booking with status: completed',
    });
  });
});
