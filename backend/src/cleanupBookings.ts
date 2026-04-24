import supabase from './utils/supabase.js';

// Cancel bookings that have been in pending_payment status for more than 30 minutes
async function cleanupUnpaidBookings() {
  const thirtyMinutesAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
  
  const { data, error } = await supabase
    .from('bookings')
    .update({ 
      status: 'cancelled',
      rejection_reason: 'Payment not completed within 30 minutes',
      updated_at: new Date().toISOString()
    })
    .eq('status', 'pending_payment')
    .eq('payment_status', 'pending')
    .lt('created_at', thirtyMinutesAgo)
    .select();

  if (error) {
    console.error('Error cleaning up unpaid bookings:', error);
  } else if (data && data.length > 0) {
    console.log(`✅ Cancelled ${data.length} unpaid booking(s)`);
  }
}

// Run every 5 minutes
setInterval(cleanupUnpaidBookings, 5 * 60 * 1000);

// Run immediately on start
cleanupUnpaidBookings();

console.log('🧹 Booking cleanup service started');
