import crypto from 'crypto';
import { paymentService } from '../domains/financial/paymentService.js';
import { BookingModel } from '../models/Booking.js';
import { expectedPaymentAmountInMinorUnits } from './marketplaceOrderPolicy.js';
import { sendEmail } from './emailService.js';

export interface PaymentRetryRequest {
  bookingId: string;
  organizationId: string;
  userId: string;
  customerEmail: string;
  callbackUrl: string;
  correlationId: string;
  idempotencyKey: string;
}

export interface PaymentRetryResult {
  success: boolean;
  payment_url?: string;
  payment_reference?: string;
  expires_at?: Date;
  retry_count?: number;
  state?: string;
  error?: string;
}

const configuredMaxRetries = (): number => {
  const value = Number(process.env.PAYMENT_MAX_RETRY_ATTEMPTS ?? 3);
  if (!Number.isInteger(value) || value < 0 || value > 20) {
    throw new Error('PAYMENT_MAX_RETRY_ATTEMPTS must be an integer between 0 and 20');
  }
  return value;
};

export const bookingPaymentRetryEligibility = (
  booking: any,
  userId: string,
  maxRetries = configuredMaxRetries(),
): { canRetry: boolean; reason?: string } => {
  if (!booking) return { canRetry: false, reason: 'Booking not found' };
  if (booking.farmer_id !== userId) {
    return { canRetry: false, reason: 'Only the farmer can retry payment' };
  }
  if (booking.status !== 'pending_payment') {
    return { canRetry: false, reason: 'Booking must be pending payment to retry' };
  }
  if (booking.payment_status !== 'failed') {
    return { canRetry: false, reason: 'Payment retry is only available for failed payments' };
  }
  if ((booking.payment_retry_count ?? 0) >= maxRetries) {
    return { canRetry: false, reason: 'Maximum payment retry attempts exceeded' };
  }
  return { canRetry: true };
};

const retryReference = (bookingId: string, idempotencyKey: string): string => {
  const fingerprint = crypto.createHash('sha256')
    .update(`${bookingId}:${idempotencyKey}`)
    .digest('hex').slice(0, 32);
  return `BOOK-${bookingId.slice(0, 8)}-${fingerprint}`;
};

export class PaymentRecoveryService {
  static async processPaymentRetry(request: PaymentRetryRequest): Promise<PaymentRetryResult> {
    try {
      const booking = await BookingModel.findByIdWithDetails(request.bookingId, request.organizationId);
      const maxRetries = configuredMaxRetries();
      if (!booking) return { success: false, error: 'Booking not found' };
      if (booking.farmer_id !== request.userId) {
        return { success: false, error: 'Only the farmer can retry payment' };
      }
      const payment = await paymentService.retryBookingPayment({
        organizationId: booking.organization_id,
        bookingId: booking.id,
        payerId: request.userId,
        actorId: request.userId,
        correlationId: request.correlationId,
        internalReference: retryReference(booking.id, request.idempotencyKey),
        idempotencyKey: request.idempotencyKey,
        amountMinor: expectedPaymentAmountInMinorUnits(booking.total_amount),
        customerEmail: request.customerEmail,
        callbackUrl: request.callbackUrl,
        maxRetries,
      });

      const expiresAt = payment.actionExpiresAt ? new Date(payment.actionExpiresAt) : undefined;
      const retryCount = Math.max(1, payment.attemptNumber - 1);
      if (!payment.idempotencyReplay) {
        await this.sendRetryNotification(booking, payment.internalReference, expiresAt, retryCount, maxRetries);
      }
      return {
        success: true,
        payment_url: payment.authorizationUrl,
        payment_reference: payment.internalReference,
        expires_at: expiresAt,
        retry_count: retryCount,
        state: payment.state,
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Failed to process payment retry',
      };
    }
  }

  static async processTimeoutCancellations(): Promise<{
    processed: number;
    cancelled: number;
    deferred: number;
    errors: string[];
  }> {
    const result = await paymentService.recoverExpiredBookingPayments();
    return {
      processed: result.processed,
      cancelled: result.cancelled,
      deferred: result.deferred,
      errors: result.errors.map((error) => `Payment ${error.paymentId}: ${error.reason}`),
    };
  }

  static async getRetryStatus(bookingId: string, userId: string, organizationId: string): Promise<{
    canRetry: boolean;
    retryCount: number;
    maxRetries: number;
    timeoutAt?: Date;
    reason?: string;
  }> {
    const maxRetries = configuredMaxRetries();
    const booking = await BookingModel.findByIdWithDetails(bookingId, organizationId);
    const eligibility = bookingPaymentRetryEligibility(booking, userId, maxRetries);
    return {
      canRetry: eligibility.canRetry,
      retryCount: Number(booking?.payment_retry_count ?? 0),
      maxRetries,
      timeoutAt: booking?.payment_timeout_at ? new Date(booking.payment_timeout_at) : undefined,
      reason: eligibility.reason,
    };
  }

  private static async sendRetryNotification(
    booking: any,
    paymentReference: string,
    expiresAt: Date | undefined,
    retryCount: number,
    maxRetries: number,
  ): Promise<void> {
    if (!booking.farmer_email) return;
    try {
      await sendEmail({
        to: booking.farmer_email,
        subject: 'Payment Retry - Complete Your Booking',
        template: 'payment-retry',
        data: {
          farmerName: booking.farmer_name,
          propertyTitle: booking.property_title,
          amount: booking.total_amount,
          paymentReference,
          expiresAt: expiresAt?.toISOString(),
          retryCount,
          maxRetries,
        },
      });
    } catch {
      // Notification failure does not change the recoverable payment state.
    }
  }
}
