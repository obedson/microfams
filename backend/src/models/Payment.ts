import { supabase } from '../utils/supabase.js';

export const PaymentModel = {
  async initiateRefund(bookingId: string, amount: number, reason: string) {
    const { data: booking } = await supabase
      .from('bookings')
      .select('payment_reference')
      .eq('id', bookingId)
      .single();

    if (!booking?.payment_reference) {
      throw new Error('No payment reference found');
    }

    // Create refund record
    const { data: refund } = await supabase
      .from('refunds')
      .insert({
        booking_id: bookingId,
        amount,
        reason,
        status: 'pending',
        payment_reference: booking.payment_reference
      })
      .select()
      .single();

    return refund;
  },

  async processRefund(refundId: string) {
    const { data: refund } = await supabase
      .from('refunds')
      .select('*')
      .eq('id', refundId)
      .single();

    if (!refund) throw new Error('Refund not found');

    // TODO: Integrate with Paystack refund API
    // For now, mark as processed
    await supabase
      .from('refunds')
      .update({ 
        status: 'processed',
        processed_at: new Date().toISOString()
      })
      .eq('id', refundId);

    return refund;
  }
};
