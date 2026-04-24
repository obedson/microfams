import { supabase } from '../utils/supabase.js';
import { BookingModel } from '../models/Booking.js';

export class AvailabilityService {
  /**
   * Find all conflicting bookings for a requested period
   */
  static async getConflictingBookings(propertyId: string, startDate: string, endDate: string) {
    const { data, error } = await supabase
      .from('bookings')
      .select('start_date, end_date')
      .eq('property_id', propertyId)
      .in('status', ['pending_payment', 'pending', 'confirmed'])
      .or(`and(start_date.lte.${endDate},end_date.gte.${startDate})`);

    if (error) throw error;
    return data || [];
  }

  /**
   * Find the next available slot for a property after a certain date
   */
  static async findNextAvailableSlot(propertyId: string, afterDate: string, durationDays: number = 30) {
    // Get all future bookings for this property
    const { data: bookings, error } = await supabase
      .from('bookings')
      .select('start_date, end_date')
      .eq('property_id', propertyId)
      .in('status', ['pending_payment', 'pending', 'confirmed'])
      .gte('end_date', afterDate)
      .order('start_date', { ascending: true });

    if (error) throw error;

    let currentCheckDate = new Date(afterDate);
    
    // If no future bookings, the next available slot is right now
    if (!bookings || bookings.length === 0) {
      return {
        start_date: currentCheckDate.toISOString().split('T')[0],
        end_date: new Date(currentCheckDate.getTime() + durationDays * 24 * 60 * 60 * 1000).toISOString().split('T')[0]
      };
    }

    // Iterate through bookings to find a gap
    for (const booking of bookings) {
      const bookingStart = new Date(booking.start_date);
      const bookingEnd = new Date(booking.end_date);

      // Check if there's enough space before this booking
      const diffMs = bookingStart.getTime() - currentCheckDate.getTime();
      const diffDays = diffMs / (1000 * 60 * 60 * 24);

      if (diffDays >= durationDays) {
        return {
          start_date: currentCheckDate.toISOString().split('T')[0],
          end_date: new Date(currentCheckDate.getTime() + durationDays * 24 * 60 * 60 * 1000).toISOString().split('T')[0]
        };
      }

      // Move current check date to after this booking
      const dayAfterBooking = new Date(bookingEnd);
      dayAfterBooking.setDate(dayAfterBooking.getDate() + 1);
      
      if (dayAfterBooking > currentCheckDate) {
        currentCheckDate = dayAfterBooking;
      }
    }

    // If no gap found between bookings, availability starts after the last booking
    return {
      start_date: currentCheckDate.toISOString().split('T')[0],
      end_date: new Date(currentCheckDate.getTime() + durationDays * 24 * 60 * 60 * 1000).toISOString().split('T')[0]
    };
  }
}
