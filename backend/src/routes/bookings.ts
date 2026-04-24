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
import { bookingLimiter } from '../middleware/rateLimiter.js';
import { detectBookingFraud } from '../middleware/fraudDetection.js';

const router = Router();

// Public routes
router.get('/property/:property_id/booked-dates', getBookedDates);

// Farmer routes
router.post('/', authenticateToken, bookingLimiter, detectBookingFraud, createBooking);
router.get('/my-bookings', authenticateToken, getMyBookings);

// Owner routes
router.get('/owner/bookings', authenticateToken, getOwnerBookings);
router.get('/owner/stats', authenticateToken, getBookingStats);

// Shared routes
router.get('/:id', authenticateToken, getBookingById);
router.put('/:id/status', authenticateToken, updateBookingStatus);
router.put('/:id/cancel', authenticateToken, cancelBooking);

// New enhanced endpoints
router.post('/:id/retry-payment', authenticateToken, retryPayment);
router.get('/:id/history', authenticateToken, getBookingHistory);
router.get('/:id/cancellation-eligibility', authenticateToken, getCancellationEligibility);
router.get('/:id/payment-retry-status', authenticateToken, getPaymentRetryStatus);

export default router;
