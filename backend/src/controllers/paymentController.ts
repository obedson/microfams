import { Request, Response } from 'express';
import axios from 'axios';
import { BookingModel } from '../models/Booking.js';
import { asyncHandler, createError } from '../middleware/errorHandler.js';
import supabase from '../utils/supabase.js';
import { ReceiptService } from '../services/receiptService.js';
import { TenantRequest } from '../middleware/tenant.js';
import { expectedPaymentAmountInMinorUnits } from '../services/marketplaceOrderPolicy.js';

const PAYSTACK_SECRET_KEY = process.env.PAYSTACK_SECRET_KEY;
const PAYSTACK_BASE_URL = 'https://api.paystack.co';
const receiptService = new ReceiptService();

export const initializePayment = asyncHandler(async (req: Request, res: Response) => {
  const { bookingId, booking_id } = req.body;
  const actualBookingId = bookingId || booking_id;
  const tenantRequest = req as TenantRequest;
  const userId = tenantRequest.user!.id;
  const organizationId = tenantRequest.tenant!.id;

  console.log('Payment request:', { actualBookingId, userId, organizationId });

  if (!PAYSTACK_SECRET_KEY) {
    throw createError('Payment service not configured', 500);
  }

  const booking = await BookingModel.findByIdWithDetails(actualBookingId, organizationId);
  console.log('Found booking:', booking);
  
  if (!booking) {
    throw createError('Booking not found', 404);
  }

  if (booking.farmer_id !== userId) {
    throw createError('Unauthorized', 403);
  }

  if (booking.payment_status === 'paid') {
    throw createError('Booking already paid', 400);
  }

  // Pre-generate reference and save to DB before Paystack call
  const reference = `BOOK-${actualBookingId.substring(0, 8)}-${Date.now()}`;
  
  const { error: preUpdateError } = await supabase
    .from('bookings')
    .update({ payment_reference: reference })
    .eq('id', actualBookingId)
    .eq('organization_id', organizationId);

  if (preUpdateError) {
    console.error('Failed to save payment intent:', preUpdateError);
    throw createError('Could not initialize payment intent', 500);
  }

  const paymentData = {
    email: (req as any).user.email,
    amount: Math.round(booking.total_amount * 100),
    reference: reference,
    callback_url: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment/callback`,
    metadata: {
      booking_id: actualBookingId,
      farmer_id: userId,
      property_id: booking.property_id
    }
  };

  try {
    const response = await axios.post(
      `${PAYSTACK_BASE_URL}/transaction/initialize`,
      paymentData,
      {
        headers: {
          Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
          'Content-Type': 'application/json'
        }
      }
    );

    res.json({
      success: true,
      data: {
        authorization_url: response.data.data.authorization_url,
        access_code: response.data.data.access_code,
        reference: reference
      }
    });
  } catch (error: any) {
    console.error('Paystack initialization error:', error.response?.data || error.message);
    throw createError('Failed to initialize payment', 500);
  }
});

export const verifyPayment = asyncHandler(async (req: Request, res: Response) => {
  const { reference } = req.params;

  if (!PAYSTACK_SECRET_KEY) {
    throw createError('Payment service not configured', 500);
  }

  try {
    const response = await axios.get(
      `${PAYSTACK_BASE_URL}/transaction/verify/${reference}`,
      {
        headers: {
          Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`
        }
      }
    );

    const { data } = response.data;
    
    if (data.status === 'success') {
      const bookingId = data.metadata?.booking_id;
      let query = supabase.from('bookings').select('*').eq('payment_reference', reference);
      if (bookingId) query = query.eq('id', bookingId);
      const { data: booking } = await query.maybeSingle();
      
      if (booking) {
        if (data.amount !== expectedPaymentAmountInMinorUnits(booking.total_amount) || data.currency !== 'NGN') {
          throw createError('Payment does not match the stored booking intent', 409);
        }
        if (booking.payment_status !== 'paid') {
          // Use atomic update
          await BookingModel.completePayment(booking.id, reference);

          // Automatically generate receipt (Requirement 9.1)
          try {
            await receiptService.generateReceipt(booking.id, reference);
          } catch (receiptError) {
            console.error(`Failed to generate receipt during verification for ${booking.id}:`, receiptError);
          }
        }
      } else {
        throw createError('Payment intent not found', 404);
        console.warn(`⚠️ verifyPayment: No booking found for reference ${reference} or ID ${bookingId}`);
      }

      res.json({
        success: true,
        data: {
          status: data.status,
          amount: data.amount / 100,
          reference: data.reference,
          paid_at: data.paid_at
        }
      });
    } else {
      res.json({
        success: false,
        error: 'Payment verification failed',
        data: { status: data.status }
      });
    }
  } catch (error: any) {
    console.error('Payment verification error:', error.response?.data || error.message);
    throw createError('Failed to verify payment', 500);
  }
});

export const getPaymentStatus = asyncHandler(async (req: Request, res: Response) => {
  const { bookingId } = req.params;
  const tenantRequest = req as TenantRequest;
  const userId = tenantRequest.user!.id;
  const organizationId = tenantRequest.tenant!.id;

  const booking = await BookingModel.findByIdWithDetails(bookingId, organizationId);
  if (!booking) {
    throw createError('Booking not found', 404);
  }

  if (booking.farmer_id !== userId) {
    throw createError('Unauthorized', 403);
  }

  res.json({
    success: true,
    data: {
      payment_status: booking.payment_status,
      booking_status: booking.status,
      payment_reference: booking.payment_reference,
      total_amount: booking.total_amount
    }
  });
});
