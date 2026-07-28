import { Request, Response } from 'express';
import axios from 'axios';
import { BookingModel } from '../models/Booking.js';
import { asyncHandler, createError } from '../middleware/errorHandler.js';

const PAYSTACK_SECRET_KEY = process.env.PAYSTACK_SECRET_KEY;
const PAYSTACK_BASE_URL = 'https://api.paystack.co';

export const initializePayment = asyncHandler(async (req: Request, res: Response) => {
  const { bookingId, booking_id } = req.body;
  const actualBookingId = bookingId || booking_id;
  const userId = (req as any).user.id;

  if (!PAYSTACK_SECRET_KEY) {
    throw createError('Payment service not configured', 500);
  }

  const booking = await BookingModel.findById(bookingId);
  if (!booking) {
    throw createError('Booking not found', 404);
  }

  if (booking.farmer_id !== userId) {
    throw createError('Unauthorized', 403);
  }

  if (booking.payment_status === 'paid') {
    throw createError('Booking already paid', 400);
  }

  const paymentData = {
    email: (req as any).user.email,
    amount: Math.round(booking.total_amount * 100), // Convert to kobo
    reference: `booking_${bookingId}_${Date.now()}`,
    callback_url: `${process.env.FRONTEND_URL}/payment/callback`,
    metadata: {
      booking_id: bookingId,
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
        reference: response.data.data.reference
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
      
      if (bookingId) {
        await BookingModel.completePayment(bookingId, reference);
      }

      res.json({
        success: true,
        data: {
          status: data.status,
          amount: data.amount / 100, // Convert from kobo
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
  const userId = (req as any).user.id;

  const booking = await BookingModel.findById(bookingId);
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
