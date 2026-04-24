import { BookingModel } from '../models/Booking.js';
import { sendEmail } from './emailService.js';
import { logAudit } from '../utils/audit.js';

export interface PaymentRetryRequest {
  bookingId: string;
  userId: string;
}

export interface PaymentRetryResult {
  success: boolean;
  payment_url?: string;
  payment_reference?: string;
  expires_at?: Date;
  retry_count?: number;
  error?: string;
}

export class PaymentRecoveryService {
  private static readonly MAX_RETRY_ATTEMPTS = 3;
  private static readonly PAYMENT_TIMEOUT_HOURS = 48;
  private static readonly RETRY_BACKOFF_MULTIPLIER = 2;

  /**
   * Processes payment retry with exponential backoff logic
   */
  static async processPaymentRetry(request: PaymentRetryRequest): Promise<PaymentRetryResult> {
    try {
      // Get booking details
      const booking = await BookingModel.findByIdWithDetails(request.bookingId);
      if (!booking) {
        return {
          success: false,
          error: 'Booking not found'
        };
      }

      // Validate retry eligibility
      const eligibility = this.validateRetryEligibility(booking, request.userId);
      if (!eligibility.canRetry) {
        return {
          success: false,
          error: eligibility.reason
        };
      }

      // Check retry limits
      const currentRetryCount = booking.payment_retry_count || 0;
      if (currentRetryCount >= this.MAX_RETRY_ATTEMPTS) {
        return {
          success: false,
          error: 'Maximum retry attempts exceeded'
        };
      }

      // Generate new payment reference with retry indicator
      const newPaymentReference = this.generatePaymentReference(booking.id, currentRetryCount + 1);
      
      // Calculate timeout with exponential backoff
      const timeoutHours = this.calculateTimeoutWithBackoff(currentRetryCount);
      const expiresAt = new Date(Date.now() + timeoutHours * 60 * 60 * 1000);

      // Update booking with new payment details
      await BookingModel.updatePaymentRetry(request.bookingId, newPaymentReference);
      await BookingModel.updatePaymentTimeout(request.bookingId, expiresAt);

      // Log audit trail
      await logAudit({
        user_id: request.userId,
        action: 'payment_retry_initiated',
        resource_type: 'booking',
        resource_id: request.bookingId,
        details: {
          retry_count: currentRetryCount + 1,
          new_payment_reference: newPaymentReference,
          expires_at: expiresAt.toISOString(),
          timeout_hours: timeoutHours
        }
      });

      // Send retry notification
      await this.sendRetryNotification(booking, newPaymentReference, expiresAt);

      // Generate payment URL (in real implementation, integrate with Paystack)
      const paymentUrl = this.generatePaymentUrl(newPaymentReference, booking.total_amount);

      return {
        success: true,
        payment_url: paymentUrl,
        payment_reference: newPaymentReference,
        expires_at: expiresAt,
        retry_count: currentRetryCount + 1
      };

    } catch (error) {
      console.error('Payment retry processing error:', error);
      return {
        success: false,
        error: 'Failed to process payment retry'
      };
    }
  }

  /**
   * Validates if payment retry is allowed
   */
  private static validateRetryEligibility(booking: any, userId: string): {
    canRetry: boolean;
    reason?: string;
  } {
    // Check authorization
    if (booking.farmer_id !== userId) {
      return { canRetry: false, reason: 'Only the farmer can retry payment' };
    }

    // Check payment status
    if (booking.payment_status !== 'failed') {
      return { canRetry: false, reason: 'Payment retry is only available for failed payments' };
    }

    // Check booking status
    if (booking.status !== 'pending_payment') {
      return { canRetry: false, reason: 'Booking must be in pending_payment status to retry payment' };
    }

    // Check if booking is cancelled
    if (booking.status === 'cancelled') {
      return { canRetry: false, reason: 'Cannot retry payment for cancelled bookings' };
    }

    return { canRetry: true };
  }

  /**
   * Generates unique payment reference with retry indicator
   */
  private static generatePaymentReference(bookingId: string, retryCount: number): string {
    const timestamp = Date.now();
    const bookingPrefix = bookingId.substring(0, 8);
    return `PAY_${timestamp}_${bookingPrefix}_R${retryCount}`;
  }

  /**
   * Calculates timeout with exponential backoff
   */
  private static calculateTimeoutWithBackoff(retryCount: number): number {
    const baseTimeout = this.PAYMENT_TIMEOUT_HOURS;
    return Math.min(baseTimeout * Math.pow(this.RETRY_BACKOFF_MULTIPLIER, retryCount), 72); // Max 72 hours
  }

  /**
   * Generates payment URL (placeholder for Paystack integration)
   */
  private static generatePaymentUrl(paymentReference: string, amount: number): string {
    // In real implementation, this would integrate with Paystack
    return `https://checkout.paystack.com/pay/${paymentReference}?amount=${amount * 100}`;
  }

  /**
   * Sends payment retry notification to farmer
   */
  private static async sendRetryNotification(booking: any, paymentReference: string, expiresAt: Date): Promise<void> {
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
          expiresAt: expiresAt.toISOString(),
          retryCount: booking.payment_retry_count + 1,
          maxRetries: this.MAX_RETRY_ATTEMPTS
        }
      });
    } catch (error) {
      console.error('Failed to send retry notification:', error);
      // Don't throw - retry should still succeed even if notification fails
    }
  }

  /**
   * Processes automatic timeout cancellation for expired payments
   */
  static async processTimeoutCancellations(): Promise<{
    processed: number;
    cancelled: number;
    errors: string[];
  }> {
    const results = {
      processed: 0,
      cancelled: 0,
      errors: [] as string[]
    };

    try {
      // Find bookings with expired payment timeouts
      const expiredBookings = await this.findExpiredPaymentBookings();
      results.processed = expiredBookings.length;

      for (const booking of expiredBookings) {
        try {
          await this.cancelExpiredBooking(booking);
          results.cancelled++;
        } catch (error) {
          console.error(`Failed to cancel expired booking ${booking.id}:`, error);
          results.errors.push(`Booking ${booking.id}: ${error}`);
        }
      }

      console.log(`Payment timeout processing completed: ${results.cancelled}/${results.processed} bookings cancelled`);
      return results;

    } catch (error) {
      console.error('Payment timeout processing error:', error);
      results.errors.push(`System error: ${error}`);
      return results;
    }
  }

  /**
   * Finds bookings with expired payment timeouts
   */
  private static async findExpiredPaymentBookings(): Promise<any[]> {
    // This would be implemented with a proper database query
    // For now, return empty array as placeholder
    return [];
  }

  /**
   * Cancels a booking due to payment timeout
   */
  private static async cancelExpiredBooking(booking: any): Promise<void> {
    try {
      // Update booking status to cancelled
      await BookingModel.updateStatus(
        booking.id,
        'cancelled',
        'Automatic cancellation due to payment timeout',
        'system'
      );

      // Log audit trail
      await logAudit({
        user_id: null, // System action
        action: 'booking_cancelled_timeout',
        resource_type: 'booking',
        resource_id: booking.id,
        details: {
          reason: 'Payment timeout after 48 hours',
          original_payment_reference: booking.payment_reference,
          retry_count: booking.payment_retry_count,
          timeout_at: booking.payment_timeout_at
        }
      });

      // Send timeout notification
      await this.sendTimeoutNotification(booking);

    } catch (error) {
      console.error(`Failed to cancel expired booking ${booking.id}:`, error);
      throw error;
    }
  }

  /**
   * Sends timeout cancellation notification
   */
  private static async sendTimeoutNotification(booking: any): Promise<void> {
    try {
      // Notify farmer
      await sendEmail({
        to: booking.farmer_email,
        subject: 'Booking Cancelled - Payment Timeout',
        template: 'payment-timeout-cancellation',
        data: {
          farmerName: booking.farmer_name,
          propertyTitle: booking.property_title,
          bookingId: booking.id,
          timeoutHours: this.PAYMENT_TIMEOUT_HOURS
        }
      });

      // Notify property owner
      await sendEmail({
        to: booking.owner_email,
        subject: 'Booking Cancelled - Payment Timeout',
        template: 'owner-booking-timeout',
        data: {
          ownerName: booking.owner_name,
          propertyTitle: booking.property_title,
          farmerName: booking.farmer_name,
          bookingId: booking.id
        }
      });

    } catch (error) {
      console.error('Failed to send timeout notifications:', error);
      // Don't throw - cancellation should still succeed
    }
  }

  /**
   * Sends payment failure notification with retry instructions
   */
  static async sendPaymentFailureNotification(booking: any, failureReason?: string): Promise<void> {
    try {
      const canRetry = (booking.payment_retry_count || 0) < this.MAX_RETRY_ATTEMPTS;
      
      await sendEmail({
        to: booking.farmer_email,
        subject: 'Payment Failed - Action Required',
        template: 'payment-failure',
        data: {
          farmerName: booking.farmer_name,
          propertyTitle: booking.property_title,
          amount: booking.total_amount,
          failureReason: failureReason || 'Payment processing failed',
          canRetry,
          retryCount: booking.payment_retry_count || 0,
          maxRetries: this.MAX_RETRY_ATTEMPTS,
          bookingId: booking.id
        }
      });

    } catch (error) {
      console.error('Failed to send payment failure notification:', error);
      // Don't throw - this is a notification service
    }
  }

  /**
   * Gets payment retry status for a booking
   */
  static async getRetryStatus(bookingId: string, userId: string): Promise<{
    canRetry: boolean;
    retryCount: number;
    maxRetries: number;
    timeoutAt?: Date;
    reason?: string;
  }> {
    try {
      const booking = await BookingModel.findByIdWithDetails(bookingId);
      
      if (!booking) {
        return {
          canRetry: false,
          retryCount: 0,
          maxRetries: this.MAX_RETRY_ATTEMPTS,
          reason: 'Booking not found'
        };
      }

      const eligibility = this.validateRetryEligibility(booking, userId);
      const retryCount = booking.payment_retry_count || 0;

      return {
        canRetry: eligibility.canRetry && retryCount < this.MAX_RETRY_ATTEMPTS,
        retryCount,
        maxRetries: this.MAX_RETRY_ATTEMPTS,
        timeoutAt: booking.payment_timeout_at ? new Date(booking.payment_timeout_at) : undefined,
        reason: eligibility.reason
      };

    } catch (error) {
      console.error('Error getting retry status:', error);
      return {
        canRetry: false,
        retryCount: 0,
        maxRetries: this.MAX_RETRY_ATTEMPTS,
        reason: 'System error'
      };
    }
  }
}