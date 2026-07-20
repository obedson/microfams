import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { BookingModel } from '../models/Booking.js';
import { GroupModel } from '../models/Group.js';
import { ContributionModel } from '../models/Contribution.js';
import supabase from '../utils/supabase.js';
import { walletController } from '../controllers/walletController.js';
import { paymentMatchesOrder, expectedPaymentAmountInMinorUnits } from '../services/marketplaceOrderPolicy.js';
import { logger } from '../utils/logger.js';

const router = Router();

export const verifyPaystackSignature = (rawBody: Buffer, signature: unknown): boolean => {
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret || typeof signature !== 'string') return false;

  const expected = crypto.createHmac('sha512', secret).update(rawBody).digest();
  let received: Buffer;
  try {
    received = Buffer.from(signature, 'hex');
  } catch {
    return false;
  }
  return received.length === expected.length && crypto.timingSafeEqual(received, expected);
};

const processMarketplacePayment = async (data: any) => {
  const orderId = data.metadata?.order_id;
  if (!orderId) throw new Error('Marketplace payment has no order identifier');

  const { data: order, error } = await supabase
    .from('orders')
    .select('id, organization_id, supplier_organization_id, total_amount, status, payment_status, payment_reference')
    .eq('id', orderId)
    .eq('payment_reference', data.reference)
    .single();

  if (error || !order) throw new Error('Marketplace payment intent not found');
  if (!paymentMatchesOrder(order, data)) throw new Error('Marketplace payment does not match the stored order intent');
  if (order.payment_status === 'paid') return;

  const { data: updated, error: updateError } = await supabase
    .from('orders')
    .update({
      status: 'confirmed',
      payment_status: 'paid',
      paid_at: data.paid_at || new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', order.id)
    .eq('organization_id', order.organization_id)
    .eq('supplier_organization_id', order.supplier_organization_id)
    .eq('payment_reference', data.reference)
    .eq('payment_status', 'pending')
    .select('id')
    .maybeSingle();

  if (updateError || !updated) throw new Error('Marketplace payment state could not be updated');
  logger.info('Marketplace payment confirmed', {
    order_id: order.id,
    organization_id: order.organization_id,
    supplier_organization_id: order.supplier_organization_id,
    reference: data.reference,
  });
};

const processBookingPayment = async (data: any) => {
  const bookingId = data.metadata?.booking_id;
  let query = supabase.from('bookings').select('*').eq('payment_reference', data.reference);
  if (bookingId) query = query.eq('id', bookingId);
  const { data: booking, error } = await query.maybeSingle();
  if (error || !booking) throw new Error('Booking payment intent not found');

  if (data.amount !== expectedPaymentAmountInMinorUnits(booking.total_amount) || data.currency !== 'NGN') {
    throw new Error('Booking payment does not match the stored booking intent');
  }
  if (booking.payment_status === 'paid') return;

  await BookingModel.completePayment(booking.id, data.reference);
  try {
    const { ReceiptService } = await import('../services/receiptService.js');
    await new ReceiptService().generateReceipt(booking.id, data.reference);
  } catch (receiptError) {
    logger.error('Receipt generation failed after verified booking payment', { booking_id: booking.id, receiptError });
  }
};

router.post('/paystack', async (req: Request, res: Response) => {
  const rawBody = Buffer.isBuffer(req.body) ? req.body : Buffer.from(JSON.stringify(req.body));
  if (!verifyPaystackSignature(rawBody, req.headers['x-paystack-signature'])) {
    return res.status(400).json({ error: 'Invalid signature' });
  }

  try {
    const event = JSON.parse(rawBody.toString('utf8'));
    if (event.event === 'charge.success') {
      const data = event.data;
      if (data.metadata?.type === 'marketplace_order') {
        await processMarketplacePayment(data);
      } else if (data.reference?.startsWith('BOOK-') || data.metadata?.booking_id) {
        await processBookingPayment(data);
      } else if (data.reference?.startsWith('GRP-')) {
        const { data: membership } = await supabase
          .from('group_members').select('id').eq('payment_reference', data.reference).single();
        if (membership) await GroupModel.confirmPayment(membership.id);
      } else if (data.reference?.startsWith('CONTRIB-')) {
        const { data: contribution } = await supabase
          .from('member_contributions').select('id').eq('payment_reference', data.reference).single();
        if (contribution) await ContributionModel.recordPayment(contribution.id, data.amount / 100, data.reference);
      }
    }
    return res.sendStatus(200);
  } catch (error) {
    logger.error('Paystack webhook processing failed', { error: error instanceof Error ? error.message : String(error) });
    return res.status(400).json({ error: 'Webhook event could not be reconciled' });
  }
});

router.post('/interswitch', async (req: Request, res: Response) => {
  try {
    if (Buffer.isBuffer(req.body)) {
      req.body = JSON.parse(req.body.toString('utf8'));
    }
    await walletController.interswitchWebhook(req, res);
  } catch (error) {
    logger.error('Interswitch webhook processing failed', { error });
    res.sendStatus(500);
  }
});

router.get('/payment/callback', (req: Request, res: Response) => {
  const { reference, trxref } = req.query;
  const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:3000';
  res.redirect(`${frontendUrl}/payment/callback?reference=${encodeURIComponent(String(reference || trxref || ''))}`);
});

export default router;
