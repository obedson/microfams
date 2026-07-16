import { Router } from 'express';
import { 
  createBooking, 
  getMyBookings, 
  getOwnerBookings,
  getBookingById,
  updateBookingStatus,
  getBookingStats,
  cancelBooking,
  getBookedDates,
  retryPayment,
  getBookingHistory,
  getCancellationEligibility,
  getPaymentRetryStatus
} from '../controllers/bookingController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { bookingLimiter } from '../middleware/rateLimiter.js';
import { detectBookingFraud } from '../middleware/fraudDetection.js';

const router = Router();

// Public routes
router.get('/property/:property_id/booked-dates', getBookedDates);

// Farmer routes
router.post('/', authenticateToken, resolveTenant, bookingLimiter, detectBookingFraud, createBooking);
router.get('/my-bookings', authenticateToken, resolveTenant, getMyBookings);

// Owner routes
router.get('/owner/bookings', authenticateToken, resolveTenant, getOwnerBookings);
router.get('/owner/stats', authenticateToken, resolveTenant, getBookingStats);

// Shared routes
router.get('/:id', authenticateToken, resolveTenant, getBookingById);
router.put('/:id/status', authenticateToken, resolveTenant, updateBookingStatus);
router.put('/:id/cancel', authenticateToken, resolveTenant, cancelBooking);

// New enhanced endpoints
router.post('/:id/retry-payment', authenticateToken, resolveTenant, retryPayment);
router.get('/:id/history', authenticateToken, resolveTenant, getBookingHistory);
router.get('/:id/cancellation-eligibility', authenticateToken, resolveTenant, getCancellationEligibility);
router.get('/:id/payment-retry-status', authenticateToken, resolveTenant, getPaymentRetryStatus);

export default router;
