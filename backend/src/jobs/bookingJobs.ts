import cron from 'node-cron';
import { supabase } from '../utils/supabase.js';
import { sendEmail } from '../services/emailService.js';

interface ExpiredBooking {
  id: string;
  organization_id: string;
  farmer_id: string;
  property_id: string;
  farmer: { email: string; name: string } | null;
  property: { title: string } | null;
}

import { logger } from '../utils/logger.js';

export const startBookingJobs = () => {
  // Auto-expire pending bookings after 48 hours
  cron.schedule('0 * * * *', async () => {
    try {
      const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000);
      
      const { data: expiredBookings, error } = await supabase
        .from('bookings')
        .select(`
          id, organization_id,
          farmer_id,
          property_id,
          farmer:users!farmer_id(email, name),
          property:properties(title)
        `)
        .eq('status', 'pending')
        .lt('created_at', twoDaysAgo.toISOString())
        .returns<ExpiredBooking[]>();

      if (error) throw error;
      if (!expiredBookings?.length) return;

      const organizations = new Map<string, string[]>();
      for (const booking of expiredBookings) {
        organizations.set(booking.organization_id, [...(organizations.get(booking.organization_id) || []), booking.id]);
      }
      for (const [organizationId, ids] of organizations) {
        const { error: updateError } = await supabase.from('bookings').update({
          status: 'cancelled',
          rejection_reason: 'Booking expired - no response from owner within 48 hours',
        }).eq('organization_id', organizationId).in('id', ids);
        if (updateError) throw updateError;
      }

      // Notify farmers
      for (const booking of expiredBookings) {
        if (booking.farmer?.email && booking.property?.title) {
          await sendEmail({
            to: booking.farmer.email,
            subject: 'Booking Expired',
            html: `<p>Your booking for <strong>${booking.property.title}</strong> has expired due to no response from the owner within 48 hours.</p>`
          });
        }
      }
      
      logger.info(`Expired ${expiredBookings.length} bookings across ${organizations.size} organizations`);
    } catch (error) {
      logger.error('Error expiring bookings', { error });
    }
  });
};
