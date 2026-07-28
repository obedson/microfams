import { supabase } from '../utils/supabase.js';
import { PropertyModel } from '../models/Property.js';
import { sendEmail } from './emailService.js';

export interface CreateBookingReservationInput {
  organizationId: string;
  actorId: string;
  propertyId: string;
  startDate: string;
  endDate: string;
  notes?: string;
  idempotencyKey: string;
  correlationId: string;
}

export interface BookingPriceSnapshot {
  currency: string;
  monthly_rate_minor: number;
  duration_days: number;
  billed_months: number;
  total_minor: number;
  pricing_version: string;
}

export interface BookingReservationResult {
  booking: Record<string, any>;
  price_snapshot: BookingPriceSnapshot;
  hold: Record<string, any>;
  idempotency_replay: boolean;
}

export const calculateMonthlyBookingPrice = (
  startDate: string,
  endDate: string,
  monthlyRateMinor: number,
): { durationDays: number; billedMonths: number; totalMinor: number } => {
  const start = Date.parse(`${startDate}T00:00:00Z`);
  const end = Date.parse(`${endDate}T00:00:00Z`);
  if (!Number.isInteger(monthlyRateMinor) || monthlyRateMinor < 0 || !Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
    throw new Error('BOOKING_PRICE_INPUT_INVALID');
  }
  const durationDays = Math.round((end - start) / 86_400_000);
  const billedMonths = Math.ceil(durationDays / 30);
  return { durationDays, billedMonths, totalMinor: monthlyRateMinor * billedMonths };
};

export const bookingReservationHttpError = (message: string): { status: number; code: string } => {
  if (message.includes('PROPERTY_NOT_FOUND')) return { status: 404, code: 'PROPERTY_NOT_FOUND' };
  if (message.includes('BOOKING_NOT_AUTHORIZED')) return { status: 403, code: 'BOOKING_NOT_AUTHORIZED' };
  if (message.includes('BOOKING_DATES_UNAVAILABLE') || message.includes('23P01')) {
    return { status: 409, code: 'BOOKING_DATES_UNAVAILABLE' };
  }
  if (message.includes('IDEMPOTENCY_REPLAY_CONFLICT')) return { status: 409, code: 'IDEMPOTENCY_REPLAY_CONFLICT' };
  if (message.includes('PROVIDER_NOT_AVAILABLE') || message.includes('PROPERTY_NOT_AVAILABLE')) {
    return { status: 409, code: 'PROPERTY_NOT_AVAILABLE' };
  }
  if (message.includes('BOOKING_') || message.includes('IDEMPOTENCY_KEY_INVALID')) {
    return { status: 400, code: message.match(/[A-Z][A-Z_]+/)?.[0] ?? 'BOOKING_REQUEST_INVALID' };
  }
  return { status: 500, code: 'BOOKING_RESERVATION_FAILED' };
};

export class BookingReservationService {
  static async create(input: CreateBookingReservationInput): Promise<BookingReservationResult> {
    const { data, error } = await supabase.rpc('create_booking_reservation', {
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_property_id: input.propertyId,
      p_start_date: input.startDate,
      p_end_date: input.endDate,
      p_notes: input.notes ?? null,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
    if (error || !data) throw error ?? new Error('BOOKING_RESERVATION_FAILED');

    const result = data as BookingReservationResult;
    if (!result.idempotency_replay) void this.notifyPropertyOwner(input, result);
    return result;
  }

  private static async notifyPropertyOwner(
    input: CreateBookingReservationInput,
    result: BookingReservationResult,
  ): Promise<void> {
    try {
      const property = await PropertyModel.findById(input.propertyId);
      if (!property?.owner_email) return;
      await sendEmail({
        to: property.owner_email,
        subject: 'New Booking Reservation',
        template: 'new-booking',
        data: {
          propertyTitle: property.title,
          startDate: input.startDate,
          endDate: input.endDate,
          amount: result.price_snapshot.total_minor / 100,
          reservationExpiresAt: result.hold.held_until,
        },
      });
    } catch {
      // The reservation is durable; notification delivery is recoverable out of band.
    }
  }
}
