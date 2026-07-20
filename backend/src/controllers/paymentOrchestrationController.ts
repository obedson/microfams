import crypto from 'crypto';
import { Request, Response } from 'express';
import { paymentService } from '../domains/financial/paymentService.js';
import { asyncHandler, createError } from '../middleware/errorHandler.js';
import { TenantRequest } from '../middleware/tenant.js';
import { BookingModel } from '../models/Booking.js';
import { expectedPaymentAmountInMinorUnits } from '../services/marketplaceOrderPolicy.js';
import { supabase } from '../utils/supabase.js';

const correlationId = (request: Request): string => {
  const candidate = request.headers['x-correlation-id'];
  return typeof candidate === 'string' && /^[0-9a-f-]{36}$/i.test(candidate)
    ? candidate
    : crypto.randomUUID();
};

export const initializePayment = asyncHandler(async (req: Request, res: Response) => {
  const request = req as TenantRequest;
  const bookingId = req.body.bookingId || req.body.booking_id;
  const booking = await BookingModel.findByIdWithDetails(bookingId, request.tenant!.id);
  if (!booking) throw createError('Booking not found', 404);
  if (booking.farmer_id !== request.user!.id) throw createError('Unauthorized', 403);
  if (booking.payment_status === 'paid') throw createError('Booking already paid', 409);
  const internalReference = booking.payment_reference
    || `BOOK-${booking.id.slice(0, 8)}-${Date.now()}`;
  const { error } = await supabase.from('bookings')
    .update({ payment_reference: internalReference })
    .eq('id', booking.id)
    .eq('organization_id', request.tenant!.id);
  if (error) throw createError('Could not persist payment intent', 500);
  const payment = await paymentService.createAndInitialize({
    organizationId: request.tenant!.id,
    sourceType: 'booking',
    sourceId: booking.id,
    payerId: request.user!.id,
    actorId: request.user!.id,
    correlationId: correlationId(req),
    internalReference,
    idempotencyKey: String(req.headers['idempotency-key'] || `booking:${booking.id}:${internalReference}`),
    amountMinor: expectedPaymentAmountInMinorUnits(booking.total_amount),
    customerEmail: request.user!.email,
    callbackUrl: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment/callback`,
    metadata: { booking_id: booking.id },
  });
  res.json({
    success: true,
    data: {
      authorization_url: payment.authorizationUrl,
      access_code: payment.accessCode,
      reference: payment.internalReference,
      state: payment.state,
      amount_minor: payment.amountMinor,
      currency: payment.currency,
    },
  });
});

export const verifyPayment = asyncHandler(async (req: Request, res: Response) => {
  const { data: payment, error } = await supabase
    .from('payments').select('id').eq('internal_reference', req.params.reference).single();
  if (error || !payment) throw createError('Payment intent not found', 404);
  const result = await paymentService.queryAndApply(payment.id);
  res.json({ success: result.state === 'succeeded', data: result });
});

export const requestRefund = asyncHandler(async (req: Request, res: Response) => {
  const request = req as TenantRequest;
  const amountMinor = Number(req.body.amount_minor);
  if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0) {
    throw createError('Refund amount must be positive integer minor units', 400);
  }
  const idempotencyKey = String(req.headers['idempotency-key'] || '');
  if (idempotencyKey.length < 8) throw createError('Idempotency-Key header is required', 400);
  const result = await paymentService.requestRefund({
    paymentId: req.params.paymentId,
    organizationId: request.tenant!.id,
    actorId: request.user!.id,
    internalReference: `REF-${req.params.paymentId.slice(0, 8)}-${Date.now()}`,
    idempotencyKey,
    amountMinor,
    reasonCode: String(req.body.reason_code || 'customer_request'),
    reason: String(req.body.reason || 'Customer refund request'),
    approvalReference: req.body.approval_reference,
  });
  res.status(202).json({ success: true, data: result });
});
