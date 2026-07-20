import { Request, Response } from 'express';
import { BookingModel } from '../models/Booking.js';
import { PropertyModel } from '../models/Property.js';
import { sendEmail } from '../services/emailService.js';
import { initiateRefund } from '../services/refundService.js';
import { BookingCancellationService } from '../services/bookingCancellationService.js';
import { PaymentRecoveryService } from '../services/paymentRecoveryService.js';
import { AvailabilityService } from '../services/availabilityService.js';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';

const bookingSchema = Joi.object({
  property_id: Joi.string().required(),
  start_date: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  end_date: Joi.string().pattern(/^\d{4}-\d{2}-\d{2}$/).required(),
  total_amount: Joi.number().positive().required(),
  notes: Joi.string().optional().allow(''),
});

const statusUpdateSchema = Joi.object({
  status: Joi.string().valid('confirmed', 'cancelled', 'completed').required(),
  rejection_reason: Joi.string().when('status', {
    is: 'cancelled',
    then: Joi.optional(),
    otherwise: Joi.forbidden()
  })
});

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
  try {
    const { error, value } = bookingSchema.validate(req.body);
    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    // Validate end_date is after start_date
    if (new Date(value.end_date) <= new Date(value.start_date)) {
      return res.status(400).json({ 
        success: false, 
        error: 'End date must be after start date' 
      });
    }

    // Verify property exists and calculate correct price
    const property = await PropertyModel.findById(value.property_id);
    if (!property) {
      return res.status(404).json({ 
        success: false, 
        error: 'Property not found' 
      });
    }

    if (!property.is_active) {
      return res.status(400).json({ 
        success: false, 
        error: 'Property is not available for booking' 
      });
    }

    // Calculate and validate total amount
    const start = new Date(value.start_date);
    const end = new Date(value.end_date);
    const days = Math.ceil((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24));
    const months = Math.ceil(days / 30);
    const calculatedAmount = months * property.price_per_month;

    if (Math.abs(value.total_amount - calculatedAmount) > 0.01) {
      return res.status(400).json({ 
        success: false, 
        error: 'Invalid total amount. Please refresh and try again.' 
      });
    }

    // Check for booking conflicts
    const conflictingBookings = await AvailabilityService.getConflictingBookings(
      value.property_id,
      value.start_date,
      value.end_date
    );

    if (conflictingBookings.length > 0) {
      const nextSlot = await AvailabilityService.findNextAvailableSlot(
        value.property_id, 
        value.end_date
      );

      return res.status(409).json({ 
        success: false, 
        error: 'Property is already booked for some of the selected dates',
        conflicts: conflictingBookings,
        suggestion: nextSlot
      });
    }

    const booking = await BookingModel.create({
      property_id: value.property_id,
      start_date: value.start_date,
      end_date: value.end_date,
      total_amount: calculatedAmount,
      farmer_id: (req as any).user.id,
      organization_id: req.tenant!.id,
      provider_organization_id: property.organization_id,
      status: 'pending_payment',
      payment_status: 'pending',
      payment_retry_count: 0,
    });

    // Send notification to owner
    await sendEmail({
      to: property.owner_email,
      subject: 'New Booking Request',
      template: 'new-booking',
      data: {
        propertyTitle: property.title,
        farmerName: (req as any).user.name,
        startDate: value.start_date,
        endDate: value.end_date,
        amount: calculatedAmount
      }
    });

    res.status(201).json({ success: true, data: booking });
  } catch (error) {
    console.error('Create booking error:', error);
    res.status(500).json({ success: false, error: 'Failed to create booking' });
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

    // Use the cancellation service for complete workflow
    const result = await BookingCancellationService.processCancellation({
      bookingId: id,
      reason: reason,
      cancelledBy: userId
    });

    if (result.success) {
      res.json(result);
    } else {
      const statusCode = result.error === 'BOOKING_NOT_FOUND' ? 404 :
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
    const userId = (req as any).user.id;

    const scopedBooking = await BookingModel.findByIdWithDetails(id, req.tenant!.id);
    if (!scopedBooking) {
      return res.status(404).json({ success: false, error: 'Booking not found' });
    }
    
    // Use the payment recovery service
    const result = await PaymentRecoveryService.processPaymentRetry({
      bookingId: id,
      userId: userId
    });

    if (result.success) {
      res.json(result);
    } else {
      const statusCode = result.error === 'Booking not found' ? 404 :
                        result.error?.includes('Only the farmer') ? 403 :
                        result.error?.includes('Maximum retry') ? 429 : 400;
      
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

    const eligibility = await BookingCancellationService.getCancellationEligibility(id, userId);

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

    const status = await PaymentRecoveryService.getRetryStatus(id, userId);

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
