import { BookingModel } from '../models/Booking.js';
import { initiateRefund } from './refundService.js';
import { sendEmail } from './emailService.js';
import { logAudit } from '../utils/audit.js';

export interface CancellationRequest {
  bookingId: string;
  reason: string;
  cancelledBy: string;
}

export interface CancellationResult {
  success: boolean;
  message: string;
  booking?: any;
  refund_status?: 'pending' | 'processed' | 'failed';
  refund_id?: string;
  error?: string;
}

export class BookingCancellationService {
  /**
   * Validates if a booking can be cancelled based on business rules
   */
  static validateCancellation(booking: any): { canCancel: boolean; reason?: string } {
    // Check if booking exists
    if (!booking) {
      return { canCancel: false, reason: 'Booking not found' };
    }

    // Check booking status - only allow cancellation for specific statuses
    const cancellableStatuses = ['pending_payment', 'pending', 'confirmed'];
    if (!cancellableStatuses.includes(booking.status)) {
      return { 
        canCancel: false, 
        reason: `Cannot cancel booking with status: ${booking.status}` 
      };
    }

    // Completed bookings cannot be cancelled
    if (booking.status === 'completed') {
      return { canCancel: false, reason: 'Cannot cancel completed bookings' };
    }

    // Already cancelled bookings cannot be cancelled again
    if (booking.status === 'cancelled') {
      return { canCancel: false, reason: 'Booking is already cancelled' };
    }

    return { canCancel: true };
  }

  /**
   * Processes the complete cancellation workflow
   */
  static async processCancellation(request: CancellationRequest): Promise<CancellationResult> {
    try {
      // Validate cancellation reason
      if (!request.reason || request.reason.trim() === '') {
        return {
          success: false,
          message: 'Cancellation reason is required',
          error: 'MISSING_REASON'
        };
      }

      // Get booking details
      const booking = await BookingModel.findByIdWithDetails(request.bookingId);
      if (!booking) {
        return {
          success: false,
          message: 'Booking not found',
          error: 'BOOKING_NOT_FOUND'
        };
      }

      // Validate cancellation eligibility
      const validation = this.validateCancellation(booking);
      if (!validation.canCancel) {
        return {
          success: false,
          message: validation.reason || 'Cannot cancel booking',
          error: 'CANCELLATION_NOT_ALLOWED'
        };
      }

      let refund_status = null;
      let refund_id = null;

      // Handle refunds for paid bookings
      if (booking.payment_status === 'paid' && booking.payment_reference) {
        const refundResult = await this.processRefund(booking, request.reason);
        refund_status = refundResult.status;
        refund_id = refundResult.refund_id;
      }

      // Update booking status to cancelled
      await BookingModel.updateStatus(
        request.bookingId, 
        'cancelled', 
        request.reason,
        request.cancelledBy
      );

      // Log audit trail
      await logAudit({
        user_id: request.cancelledBy,
        action: 'booking_cancelled',
        resource_type: 'booking',
        resource_id: request.bookingId,
        details: {
          reason: request.reason,
          previous_status: booking.status,
          refund_initiated: !!refund_status
        }
      });

      // Send notifications
      await this.sendCancellationNotifications(booking, request);

      // Get updated booking details
      const updatedBooking = await BookingModel.findByIdWithDetails(request.bookingId);

      const result: CancellationResult = {
        success: true,
        message: 'Booking cancelled successfully',
        booking: updatedBooking
      };

      if (refund_status) {
        result.refund_status = refund_status as 'pending' | 'processed' | 'failed';
        if (refund_id) {
          result.refund_id = refund_id;
        }
      }

      return result;

    } catch (error) {
      console.error('Cancellation processing error:', error);
      return {
        success: false,
        message: 'Failed to process cancellation',
        error: 'PROCESSING_ERROR'
      };
    }
  }

  /**
   * Processes refund for paid bookings
   */
  private static async processRefund(booking: any, reason: string): Promise<{ status: string; refund_id?: string }> {
    try {
      const refundResult = await initiateRefund(
        booking.payment_reference,
        booking.total_amount,
        reason
      );

      if (refundResult.success) {
        console.log(`✅ Refund initiated for booking ${booking.id}: ${booking.payment_reference}`);
        return { 
          status: 'pending', 
          refund_id: refundResult.data?.id || refundResult.data?.reference
        };
      } else {
        console.error(`❌ Refund failed for booking ${booking.id}:`, refundResult.error);
        return { status: 'failed' };
      }
    } catch (error) {
      console.error('Refund processing error:', error);
      return { status: 'failed' };
    }
  }

  /**
   * Sends cancellation notifications to relevant parties
   */
  private static async sendCancellationNotifications(booking: any, request: CancellationRequest): Promise<void> {
    try {
      // Determine who to notify (the other party)
      const isFarmerCancelling = booking.farmer_id === request.cancelledBy;
      const notifyEmail = isFarmerCancelling ? booking.owner_email : booking.farmer_email;
      const cancelledBy = isFarmerCancelling ? 'farmer' : 'owner';

      // Send cancellation notification
      await sendEmail({
        to: notifyEmail,
        subject: 'Booking Cancelled',
        template: 'booking-cancelled',
        data: {
          propertyTitle: booking.property_title,
          cancelledBy,
          reason: request.reason,
          startDate: booking.start_date,
          endDate: booking.end_date,
          farmerName: booking.farmer_name,
          ownerName: booking.owner_name
        }
      });

      // Send confirmation to the person who cancelled
      const confirmationEmail = isFarmerCancelling ? booking.farmer_email : booking.owner_email;
      await sendEmail({
        to: confirmationEmail,
        subject: 'Booking Cancellation Confirmed',
        template: 'cancellation-confirmation',
        data: {
          propertyTitle: booking.property_title,
          reason: request.reason,
          startDate: booking.start_date,
          endDate: booking.end_date,
          refundStatus: booking.payment_status === 'paid' ? 'Refund initiated' : 'No refund required'
        }
      });

    } catch (error) {
      console.error('Failed to send cancellation notifications:', error);
      // Don't throw error - cancellation should still succeed even if notifications fail
    }
  }

  /**
   * Gets cancellation eligibility for a booking
   */
  static async getCancellationEligibility(bookingId: string, userId: string): Promise<{
    canCancel: boolean;
    reason?: string;
    requiresRefund: boolean;
  }> {
    try {
      const booking = await BookingModel.findByIdWithDetails(bookingId);
      
      if (!booking) {
        return { canCancel: false, reason: 'Booking not found', requiresRefund: false };
      }

      // Check authorization
      if (booking.farmer_id !== userId && booking.owner_id !== userId) {
        return { canCancel: false, reason: 'Unauthorized', requiresRefund: false };
      }

      const validation = this.validateCancellation(booking);
      
      return {
        canCancel: validation.canCancel,
        reason: validation.reason,
        requiresRefund: booking.payment_status === 'paid'
      };

    } catch (error) {
      console.error('Error checking cancellation eligibility:', error);
      return { canCancel: false, reason: 'System error', requiresRefund: false };
    }
  }
}