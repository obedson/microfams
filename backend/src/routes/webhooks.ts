import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { BookingModel } from '../models/Booking.js';
import { GroupModel } from '../models/Group.js';
import { ContributionModel } from '../models/Contribution.js';
import supabase from '../utils/supabase.js';
import { walletController } from '../controllers/walletController.js';

const router = Router();

// Verify Paystack signature
const verifyPaystackSignature = (req: Request): boolean => {
  const hash = crypto
    .createHmac('sha512', process.env.PAYSTACK_SECRET_KEY!)
    .update(JSON.stringify(req.body))
    .digest('hex');
  
  return hash === req.headers['x-paystack-signature'];
};

router.post('/paystack', async (req: Request, res: Response) => {
  try {
    // Verify signature
    if (!verifyPaystackSignature(req)) {
      console.error('Invalid Paystack signature');
      return res.status(400).json({ error: 'Invalid signature' });
    }

    const event = req.body;
    console.log('Paystack webhook event:', event.event);

    // Handle successful charge
    if (event.event === 'charge.success') {
      const { reference, amount, metadata } = event.data;
      console.log(`💳 Processing successful charge: ${reference}`, { metadata });
      
      // Handle property booking payment
      if (reference.startsWith('BOOK-') || metadata?.booking_id) {
        const bookingId = metadata?.booking_id;
        
        // Find booking by ID (preferred) or reference
        let query = supabase.from('bookings').select('*');
        if (bookingId) {
          query = query.eq('id', bookingId);
        } else {
          query = query.eq('payment_reference', reference);
        }
        
        const { data: booking, error: fetchError } = await query.maybeSingle();

        if (fetchError) {
          console.error(`❌ Error fetching booking:`, fetchError);
          return res.status(500).json({ error: 'Database fetch error' });
        }

        if (booking) {
          // Only update if booking is still in pending_payment status
          if (booking.status === 'pending_payment' || booking.payment_status !== 'paid') {
            try {
              // Use atomic update
              await BookingModel.completePayment(booking.id, reference);
              console.log(`✅ Booking ${booking.id} confirmed via webhook`);
              
              // Generate receipt automatically
              try {
                const { ReceiptService } = await import('../services/receiptService.js');
                const receiptService = new ReceiptService();
                await receiptService.generateReceipt(booking.id, reference);
                console.log(`✅ Receipt generated for booking ${booking.id}`);
              } catch (receiptError) {
                console.error(`❌ Receipt generation failed for ${booking.id}:`, receiptError);
              }
            } catch (updateError) {
              console.error(`❌ Failed to update booking ${booking.id}:`, updateError);
              return res.status(500).json({ error: 'Database update error' });
            }
          } else {
            console.log(`⚠️ Booking ${booking.id} already processed (Status: ${booking.status})`);
          }
        } else {
          console.error(`❌ Booking not found for reference ${reference} or ID ${bookingId}`);
        }
      }
      
      // Handle marketplace order payment
      else if (metadata?.type === 'marketplace_order' && metadata?.order_id) {
        const { error } = await supabase
          .from('orders')
          .update({ 
            status: 'confirmed',
            updated_at: new Date().toISOString()
          })
          .eq('id', metadata.order_id);

        if (!error) {
          console.log(`✅ Marketplace order payment confirmed: ${reference}`);
        } else {
          console.error('Failed to update order:', error);
        }
      }
      
      // Check if it's a group join payment
      else if (reference.startsWith('GRP-')) {
        const { data: membership } = await supabase
          .from('group_members')
          .select('*')
          .eq('payment_reference', reference)
          .single();

        if (membership) {
          await GroupModel.confirmPayment(membership.id);
          console.log(`✅ Group payment confirmed: ${reference}`);
        }
      }
      
      // Check if it's a contribution payment
      else if (reference.startsWith('CONTRIB-')) {
        const { data: contribution } = await supabase
          .from('member_contributions')
          .select('*')
          .eq('payment_reference', reference)
          .single();

        if (contribution) {
          await ContributionModel.recordPayment(
            contribution.id,
            amount / 100, // Paystack amount is in kobo
            reference
          );
          console.log(`✅ Contribution payment confirmed: ${reference}`);
        }
      }
    }

    res.sendStatus(200);
  } catch (error) {
    console.error('Webhook error:', error);
    res.sendStatus(500);
  }
});

router.post('/interswitch', async (req: Request, res: Response) => {
  try {
    await walletController.interswitchWebhook(req, res);
  } catch (error) {
    console.error('Interswitch webhook error:', error);
    res.sendStatus(500);
  }
});

// Callback redirect endpoint
router.get('/payment/callback', (req: Request, res: Response) => {
  const { reference, trxref } = req.query;
  // Redirect to frontend with payment reference
  res.redirect(`http://localhost:3000/payment/callback?reference=${reference || trxref}`);
});

export default router;
