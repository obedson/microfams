import { paymentService } from '../domains/financial/paymentService.js';
import { BookingModel } from '../models/Booking.js';
import { supabase } from '../utils/supabase.js';
import { sendEmail } from './emailService.js';

export type BookingCancellationOutcome =
  | 'refund_not_required'
  | 'refund_created'
  | 'refund_processing'
  | 'refund_succeeded'
  | 'refund_failed'
  | 'manual_review';

export interface CancellationRequest {
  bookingId: string;
  organizationId: string;
  reason: string;
  cancelledBy: string;
  idempotencyKey: string;
  correlationId: string;
}

export interface CancellationResult {
  success: boolean;
  message: string;
  cancellation?: Record<string, unknown>;
  booking?: unknown;
  refund_status?: BookingCancellationOutcome;
  refund_id?: string;
  error?: string;
}

export const validateBookingCancellation = (booking: any): { canCancel: boolean; reason?: string } => {
  if (!booking) return { canCancel: false, reason: 'Booking not found' };
  if (!['pending_payment', 'pending', 'confirmed'].includes(booking.status)) {
    return { canCancel: false, reason: `Cannot cancel booking with status: ${booking.status}` };
  }
  return { canCancel: true };
};

const databaseErrorCode = (message: string): string => {
  if (message.includes('not found')) return 'BOOKING_NOT_FOUND';
  if (message.includes('not authorized')) return 'UNAUTHORIZED';
  if (message.includes('status') || message.includes('reason')) return 'CANCELLATION_NOT_ALLOWED';
  if (message.includes('replay')) return 'IDEMPOTENCY_CONFLICT';
  return 'PROCESSING_ERROR';
};

export class BookingRefundOrchestrationService {
  static async processCancellation(request: CancellationRequest): Promise<CancellationResult> {
    const { data, error } = await supabase.rpc('cancel_booking_with_refund', {
      p_booking_id: request.bookingId,
      p_acting_organization_id: request.organizationId,
      p_actor_id: request.cancelledBy,
      p_reason: request.reason,
      p_idempotency_key: request.idempotencyKey,
      p_correlation_id: request.correlationId,
    });
    if (error || !data) {
      const message = error?.message ?? 'Cancellation could not be recorded';
      return { success: false, message, error: databaseErrorCode(message) };
    }

    let cancellation = data as Record<string, any>;
    if (cancellation.outcome === 'refund_created' && cancellation.refund_id) {
      try {
        const refund = await paymentService.submitRefund(
          cancellation.refund_id,
          cancellation.organization_id,
          request.cancelledBy,
        );
        cancellation = {
          ...cancellation,
          outcome: refund.state === 'succeeded'
            ? 'refund_succeeded'
            : refund.state === 'failed' || refund.state === 'cancelled'
              ? 'refund_failed'
              : 'refund_processing',
        };
      } catch {
        // The durable refund obligation remains recoverable by the payment recovery job.
        cancellation = { ...cancellation, outcome: 'refund_processing' };
      }
    }

    const booking = await BookingModel.findByIdWithDetails(request.bookingId, request.organizationId);
    if (booking) void this.sendNotifications(booking, request, cancellation.outcome);
    return {
      success: true,
      message: cancellation.outcome === 'manual_review'
        ? 'Booking cancelled; refund requires review'
        : 'Booking cancelled successfully',
      cancellation,
      booking,
      refund_status: cancellation.outcome,
      refund_id: cancellation.refund_id ?? undefined,
    };
  }

  static async getCancellationEligibility(bookingId: string, organizationId: string, userId: string) {
    const booking = await BookingModel.findByIdWithDetails(bookingId, organizationId);
    if (!booking) return { canCancel: false, reason: 'Booking not found', requiresRefund: false };
    const { data: membership } = await supabase.from('organization_memberships')
      .select('permissions,status').eq('organization_id', organizationId).eq('user_id', userId).single();
    const ownerOrFarmer = booking.farmer_id === userId || booking.owner_id === userId;
    const support = membership?.status === 'active'
      && (membership.permissions?.includes('booking.cancel.support')
        || membership.permissions?.includes('booking.*'));
    if (!ownerOrFarmer && !support) {
      return { canCancel: false, reason: 'Unauthorized', requiresRefund: false };
    }
    const validation = validateBookingCancellation(booking);
    return {
      ...validation,
      requiresRefund: booking.payment_status === 'paid',
      timing: new Date(`${booking.start_date}T00:00:00`) > new Date() ? 'pre_start' : 'on_or_after_start',
    };
  }

  static async proposeManualRefund(input: {
    cancellationId: string; organizationId: string; actorId: string;
    amountMinor: number; reason: string; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('propose_booking_refund', {
      p_cancellation_id: input.cancellationId,
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_amount_minor: input.amountMinor,
      p_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
    });
    if (error || !data) throw error ?? new Error('Refund proposal could not be created');
    return data;
  }

  static async decideManualRefund(input: {
    approvalId: string; organizationId: string; actorId: string; approve: boolean;
    reason: string; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('decide_booking_refund', {
      p_approval_id: input.approvalId,
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_approve: input.approve,
      p_decision_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
    });
    if (error || !data) throw error ?? new Error('Refund decision could not be recorded');
    if (input.approve && data.refund_id) {
      try {
        await paymentService.submitRefund(data.refund_id, input.organizationId, input.actorId);
      } catch {
        // Recovery owns retries after the database has accepted the obligation.
      }
    }
    return data;
  }

  private static async sendNotifications(
    booking: any,
    request: CancellationRequest,
    outcome: BookingCancellationOutcome,
  ): Promise<void> {
    try {
      const farmerCancelled = booking.farmer_id === request.cancelledBy;
      await Promise.all([
        sendEmail({
          to: farmerCancelled ? booking.owner_email : booking.farmer_email,
          subject: 'Booking Cancelled',
          template: 'booking-cancelled',
          data: {
            propertyTitle: booking.property_title,
            cancelledBy: farmerCancelled ? 'farmer' : 'owner',
            reason: request.reason,
            startDate: booking.start_date,
            endDate: booking.end_date,
            farmerName: booking.farmer_name,
            ownerName: booking.owner_name,
          },
        }),
        sendEmail({
          to: farmerCancelled ? booking.farmer_email : booking.owner_email,
          subject: 'Booking Cancellation Confirmed',
          template: 'cancellation-confirmation',
          data: {
            propertyTitle: booking.property_title,
            reason: request.reason,
            startDate: booking.start_date,
            endDate: booking.end_date,
            refundStatus: outcome,
          },
        }),
      ]);
    } catch {
      // Notification delivery is deliberately outside the cancellation transaction.
    }
  }
}
