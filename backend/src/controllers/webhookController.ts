import { Request, Response } from 'express';
import crypto from 'crypto';
import { BookingModel } from '../models/Booking.js';
import { ReceiptService } from '../services/receiptService.js';
import { asyncHandler, createError } from '../middleware/errorHandler.js';

const receiptService = new ReceiptService();

const verifyPaystackSignature = (payload: string, signature: string): boolean => {
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret) return false;
  
  const hash = crypto
    .createHmac('sha512', secret)
    .update(payload)
    .digest('hex');
  
  return hash === signature;
};

export const paystackWebhook = asyncHandler(async (req: Request, res: Response) => {
  const signature = req.headers['x-paystack-signature'] as string;
  const payload = JSON.stringify(req.body);

  if (!verifyPaystackSignature(payload, signature)) {
    throw createError('Invalid signature', 400);
  }

  const { event, data } = req.body;

  switch (event) {
    case 'charge.success':
      await handleSuccessfulPayment(data);
      break;
    
    case 'charge.failed':
      await handleFailedPayment(data);
      break;
    
    default:
      console.log(`Unhandled webhook event: ${event}`);
  }

  res.status(200).json({ status: 'success' });
});

const handleSuccessfulPayment = async (data: any) => {
  const { reference, amount, metadata } = data;
  const bookingId = metadata?.booking_id;

  if (!bookingId) {
    console.error('No booking ID in payment metadata');
    return;
  }

  try {
    await BookingModel.completePayment(bookingId, reference);
    
    console.log(`Payment successful for booking ${bookingId}, amount: ${amount}`);
    
    // Generate receipt automatically with proper error handling
    try {
      console.log(`Generating receipt for booking ${bookingId}, reference: ${reference}`);
      const receipt = await receiptService.generateReceipt(bookingId, reference);
      
      if (receipt) {
        console.log(`Receipt generated successfully: ${receipt.receipt_number}`);
      } else {
        console.error(`Receipt generation returned null for booking ${bookingId}`);
      }
    } catch (receiptError) {
      console.error(`Receipt generation failed for booking ${bookingId}:`, receiptError);
      // Don't fail the payment - receipt can be generated later
    }
  } catch (error) {
    console.error('Error updating booking after successful payment:', error);
  }
};

const handleFailedPayment = async (data: any) => {
  const { reference, metadata } = data;
  const bookingId = metadata?.booking_id;

  if (!bookingId) {
    console.error('No booking ID in payment metadata');
    return;
  }

  try {
    await BookingModel.updatePaymentStatus(bookingId, 'failed', reference);
    
    console.log(`Payment failed for booking ${bookingId}`);
  } catch (error) {
    console.error('Error updating booking after failed payment:', error);
  }
};
