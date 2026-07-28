import { BookingModel } from '../models/Booking.js';
import { supabase } from '../utils/supabase.js';
import { sendEmail } from './emailService.js';

export type ManagedBookingStatus = 'confirmed' | 'completed';

export interface BookingTransitionInput {
  bookingId: string;
  organizationId: string;
  actorId: string;
  targetStatus: ManagedBookingStatus;
  idempotencyKey: string;
  correlationId: string;
}

export interface BookingTransitionResult {
  transition: Record<string, unknown>;
  booking: Record<string, any>;
  idempotency_replay: boolean;
}

export const isLegalManagedBookingTransition = (
  currentStatus: string,
  targetStatus: string,
  paymentStatus: string,
  endDate?: string,
  today = new Date().toISOString().slice(0, 10),
): boolean => {
  if (paymentStatus !== 'paid') return false;
  if (currentStatus === 'pending' && targetStatus === 'confirmed') return true;
  return currentStatus === 'confirmed'
    && targetStatus === 'completed'
    && Boolean(endDate)
    && today >= endDate!;
};

export const bookingTransitionHttpError = (message: string): { status: number; code: string } => {
  if (message.includes('BOOKING_NOT_FOUND')) return { status: 404, code: 'BOOKING_NOT_FOUND' };
  if (message.includes('NOT_AUTHORIZED')) return { status: 403, code: 'BOOKING_TRANSITION_NOT_AUTHORIZED' };
  if (message.includes('IDEMPOTENCY_REPLAY_CONFLICT')) return { status: 409, code: 'IDEMPOTENCY_REPLAY_CONFLICT' };
  if (message.includes('COMPLETION_TOO_EARLY')) return { status: 409, code: 'BOOKING_COMPLETION_TOO_EARLY' };
  if (message.includes('PAYMENT_REQUIRED')) return { status: 409, code: 'BOOKING_PAYMENT_REQUIRED' };
  if (message.includes('TRANSITION_INVALID')) return { status: 409, code: 'BOOKING_TRANSITION_INVALID' };
  if (message.includes('TARGET_INVALID') || message.includes('IDEMPOTENCY_KEY_INVALID')) {
    return { status: 400, code: message.match(/[A-Z][A-Z_]+/)?.[0] ?? 'BOOKING_TRANSITION_REQUEST_INVALID' };
  }
  return { status: 500, code: 'BOOKING_TRANSITION_FAILED' };
};

export class BookingLifecycleService {
  static async transition(input: BookingTransitionInput): Promise<BookingTransitionResult> {
    const { data, error } = await supabase.rpc('transition_booking_state', {
      p_booking_id: input.bookingId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_target_status: input.targetStatus,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
    if (error || !data) throw error ?? new Error('BOOKING_TRANSITION_FAILED');

    const result = data as BookingTransitionResult;
    const booking = await BookingModel.findByIdWithDetails(input.bookingId, input.organizationId);
    const enriched = { ...result, booking: booking ?? result.booking };
    if (!result.idempotency_replay && booking) void this.notifyFarmer(booking, input.targetStatus);
    return enriched;
  }

  private static async notifyFarmer(booking: any, status: ManagedBookingStatus): Promise<void> {
    try {
      if (!booking.farmer_email) return;
      await sendEmail({
        to: booking.farmer_email,
        subject: status === 'confirmed' ? 'Booking Confirmed' : 'Booking Completed',
        template: 'booking-status-update',
        data: {
          propertyTitle: booking.property_title,
          status,
          startDate: booking.start_date,
          endDate: booking.end_date,
        },
      });
    } catch {
      // The state transition is durable; notification recovery is independent.
    }
  }
}
