import crypto from 'crypto';
import { Request, Response } from 'express';
import { BookingModel } from '../models/Booking.js';
import { sendEmail } from '../services/emailService.js';
import { BookingRefundOrchestrationService } from '../services/bookingRefundOrchestrationService.js';
import { PaymentRecoveryService } from '../services/paymentRecoveryService.js';
import { AvailabilityService } from '../services/availabilityService.js';
import { BookingReservationService, bookingReservationHttpError } from '../services/bookingReservationService.js';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';

const bookingSchema = Joi.object({
  property_id: Joi.string().required(),
  start_date: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  end_date: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  total_amount: Joi.number().positive().optional().strip(),
  notes: Joi.string().max(2000).optional().allow(''),
});

const statusUpdateSchema = Joi.object({
  status: Joi.string().valid('confirmed', 'cancelled', 'completed').required(),
  rejection_reason: Joi.string().when('status', {
    is: 'cancelled',
    then: Joi.optional(),
    otherwise: Joi.forbidden()
  })
});

const requestCorrelationId = (request: Request): string => {
  const candidate = request.headers['x-correlation-id'];
  return typeof candidate === 'string' && /^[0-9a-f-]{36}$/i.test(candidate)
    ? candidate
    : crypto.randomUUID();
};

export const getBookedDates = async (req: Request, res: Response) => {
  try {
    const { property_id } = req.params;
    
    const bookedDates = await BookingModel.getBookedDates(property_id);
    const nextSlot = await AvailabilityService.findNextAvailableSlot(
      property_id, 
      new Date().toISOString().split('T')[0]
    );
    
    res.json({ 
      success: true, 
      data: bookedDates,
      suggestion: nextSlot
    });
  } catch (error: any) {
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
};

export const createBooking = async (req: TenantRequest, res: Response) => {
  const { error, value } = bookingSchema.validate(req.body);
  if (error) return res.status(400).json({ success: false, error: 'BOOKING_REQUEST_INVALID', message: error.details[0].message });

  const idempotencyKey = req.headers['idempotency-key'];
  if (typeof idempotencyKey !== 'string') {
    return res.status(400).json({ success: false, error: 'IDEMPOTENCY_KEY_REQUIRED' });
  }

  try {
    const result = await BookingReservationService.create({
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      propertyId: value.property_id,
      startDate: value.start_date,
      endDate: value.end_date,
      notes: value.notes,
      idempotencyKey,
      correlationId: requestCorrelationId(req),
    });
    return res.status(result.idempotency_replay ? 200 : 201).json({ success: true, data: result });
  } catch (error: any) {
    const mapped = bookingReservationHttpError(error?.message ?? 'BOOKING_RESERVATION_FAILED');
    if (mapped.code === 'BOOKING_DATES_UNAVAILABLE') {
      const suggestion = await AvailabilityService.findNextAvailableSlot(value.property_id, value.end_date);
      return res.status(mapped.status).json({ success: false, error: mapped.code, suggestion });
    }
    return res.status(mapped.status).json({ success: false, error: mapped.code });
  }
};
export const getMyBookings = async (req: TenantRequest, res: Response) => {
  try {
    const {
      status,
      payment_status,
      property_id,
      date_from,
      date_to,
      search,
      page = '1',
      limit = '10'
    } = req.query;

    const filters = {
      status: status ? (status as string).split(',') : undefined,
      payment_status: payment_status ? (payment_status as string).split(',') : undefined,
      property_id: property_id as string,
      date_from: date_from as string,
      date_to: date_to as string,
      search: search as string,
      page: parseInt(page as string),
      limit: parseInt(limit as string)
    };

    const result = await BookingModel.findByFarmerWithFilters((req as any).user.id, req.tenant!.id, filters);
    
    res.json({ 
      success: true, 
      data: result.bookings,
      pagination: result.pagination,
      filters_applied: filters
    });
  } catch (error) {
    console.error('Get my bookings error:', error);
    res.status(500).json({ success: false, error: 'Failed to fetch bookings' });
  }
};

export const getOwnerBookings = async (req: TenantRequest, res: Response) => {
  try {
    const {
      status,
      payment_status,
      property_id,
      date_from,
      date_to,
      search,
      page = '1',
      limit = '10'
    } = req.query;

    const filters = {
      status: status ? (status as string).split(',') : undefined,
      payment_status: payment_status ? (payment_status as string).split(',') : undefined,
      property_id: property_id as string,
      date_from: date_from as string,
      date_to: date_to as string,
      search: search as string,
      page: parseInt(page as string),
      limit: parseInt(limit as string)
    };

    const result = await BookingModel.findByOwnerWithFilters((req as any).user.id, req.tenant!.id, filters);
    
    res.json({ 
      success: true, 
      data: result.bookings,
      pagination: result.pagination,
      filters_applied: filters
    });
  } catch (error) {
    console.error('Get owner bookings error:', error);
    res.status(500).json({ success: false, error: 'Failed to fetch bookings' });
  }
};

export const getBookingById = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const booking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);

    if (!booking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    // Check authorization
    const userId = (req as any).user.id;
    const userRole = (req as any).user.role;
    
    if (booking.farmer_id !== userId && booking.owner_id !== userId && userRole !== 'admin') {
      return res.status(403).json({ success: false, error: 'Unauthorized' });
    }

    res.json({ success: true, data: booking });
  } catch (error) {
    console.error('Get booking error:', error);
    res.status(500).json({ success: false, error: 'Failed to fetch booking' });
  }
};

export const updateBookingStatus = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { error, value } = statusUpdateSchema.validate(req.body);
    
    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }
    if (value.status === 'cancelled') {
      return res.status(409).json({
        success: false,
        error: 'Use the booking cancellation endpoint so refund policy is applied',
      });
    }

    const booking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!booking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    // Verify owner authorization
    if (booking.owner_id !== (req as any).user.id) {
      return res.status(403).json({ success: false, error: 'Only property owner can update booking status' });
    }

    // Validate status transitions
    if (booking.status === 'completed' || booking.status === 'cancelled') {
      return res.status(400).json({ 
        success: false, 
        error: 'Cannot update status of completed or cancelled bookings' 
      });
    }

    if (value.status === 'confirmed' && booking.payment_status !== 'paid') {
      return res.status(400).json({ 
        success: false, 
        error: 'Cannot confirm booking until payment is completed' 
      });
    }

    await BookingModel.updateStatus(id, value.status, value.rejection_reason, undefined, req.tenant!.id);

    // Send notification to farmer
    await sendEmail({
      to: booking.farmer_email,
      subject: `Booking ${value.status === 'confirmed' ? 'Confirmed' : 'Cancelled'}`,
      template: 'booking-status-update',
      data: {
        propertyTitle: booking.property_title,
        status: value.status,
        rejectionReason: value.rejection_reason,
        startDate: booking.start_date,
        endDate: booking.end_date
      }
    });

    res.json({ success: true, message: 'Booking status updated successfully' });
  } catch (error) {
    console.error('Update booking status error:', error);
    res.status(500).json({ success: false, error: 'Failed to update booking status' });
  }
};

export const getBookingStats = async (req: TenantRequest, res: Response) => {
  try {
    const stats = await BookingModel.getOwnerStats((req as any).user.id, req.tenant!.id);
    res.json({ success: true, data: stats });
  } catch (error) {
    console.error('Get booking stats error:', error);
    res.status(500).json({ success: false, error: 'Failed to fetch booking statistics' });
  }
};

export const cancelBooking = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;
    const userId = (req as any).user.id;

    const scopedBooking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!scopedBooking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    const idempotencyKey = String(req.headers['idempotency-key'] ?? '');
    if (idempotencyKey.length < 8) {
      return res.status(400).json({ success: false, error: 'Idempotency-Key header is required' });
    }

    const result = await BookingRefundOrchestrationService.processCancellation({
      bookingId: id,
      organizationId: req.tenant!.id,
      reason,
      cancelledBy: userId,
      idempotencyKey,
      correlationId: requestCorrelationId(req),
    });

    if (result.success) {
      res.json(result);
    } else {
      const statusCode = result.error === 'BOOKING_NOT_FOUND' ? 404 :
                        result.error === 'UNAUTHORIZED' ? 403 :
                        result.error === 'IDEMPOTENCY_CONFLICT' ? 409 :
                        result.error === 'MISSING_REASON' ? 400 :
                        result.error === 'CANCELLATION_NOT_ALLOWED' ? 400 : 500;
      
      res.status(statusCode).json({
        success: false,
        error: result.message
      });
    }
  } catch (error) {
    console.error('Cancel booking error:', error);
    res.status(500).json({ success: false, error: 'Failed to cancel booking' });
  }
};

export const retryPayment = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const userId = req.user!.id;
    const idempotencyKey = String(req.headers['idempotency-key'] ?? '');
    if (idempotencyKey.length < 8) {
      return res.status(400).json({ success: false, error: 'Idempotency-Key header is required' });
    }

    const scopedBooking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!scopedBooking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }
    
    // Use the payment recovery service
    const result = await PaymentRecoveryService.processPaymentRetry({
      bookingId: id,
      organizationId: scopedBooking.organization_id,
      userId,
      customerEmail: req.user!.email,
      callbackUrl: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment/callback`,
      correlationId: requestCorrelationId(req),
      idempotencyKey,
    });

    if (result.success) {
      res.json(result);
    } else {
      const statusCode = result.error === 'Booking not found' ? 404 :
                        result.error?.includes('Only the farmer') ? 403 :
                        result.error?.includes('Maximum') ? 429 :
                        result.error?.includes('active attempt') ? 409 : 400;
      
      res.status(statusCode).json({
        success: false,
        error: result.error
      });
    }
  } catch (error) {
    console.error('Retry payment error:', error);
    res.status(500).json({ success: false, error: 'Failed to retry payment' });
  }
};

export const getBookingHistory = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    
    const booking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!booking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    // Check authorization
    const userId = (req as any).user.id;
    const userRole = (req as any).user.role;
    
    if (booking.farmer_id !== userId && booking.owner_id !== userId && userRole !== 'admin') {
      return res.status(403).json({ success: false, error: 'Unauthorized' });
    }

    const history = await BookingModel.getBookingHistory(id);

    res.json({
      success: true,
      booking_id: id,
      history: history.status_history,
      audit_logs: history.audit_logs
    });
  } catch (error) {
    console.error('Get booking history error:', error);
    res.status(500).json({ success: false, error: 'Failed to fetch booking history' });
  }
};

export const getCancellationEligibility = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const userId = (req as any).user.id;

    const scopedBooking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!scopedBooking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    const eligibility = await BookingRefundOrchestrationService.getCancellationEligibility(id, req.tenant!.id, userId);

    res.json({
      success: true,
      booking_id: id,
      ...eligibility
    });
  } catch (error) {
    console.error('Get cancellation eligibility error:', error);
    res.status(500).json({ success: false, error: 'Failed to check cancellation eligibility' });
  }
};

export const getPaymentRetryStatus = async (req: TenantRequest, res: Response) => {
  try {
    const { id } = req.params;
    const userId = (req as any).user.id;

    const scopedBooking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!scopedBooking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }

    const status = await PaymentRecoveryService.getRetryStatus(id, userId, scopedBooking.organization_id);

    res.json({
      success: true,
      booking_id: id,
      ...status
    });
  } catch (error) {
    console.error('Get payment retry status error:', error);
    res.status(500).json({ success: false, error: 'Failed to check payment retry status' });
  }
};
