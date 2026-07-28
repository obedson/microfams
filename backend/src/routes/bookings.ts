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
import { decideBookingRefund, proposeBookingRefund } from '../controllers/bookingRefundController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { bookingLimiter } from '../middleware/rateLimiter.js';
import { detectBookingFraud } from '../middleware/fraudDetection.js';

const router = Router();

// Public routes
router.get('/property/:property_id/booked-dates', getBookedDates);

// Farmer routes
router.post(
  '/',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.reservations.create'),
  bookingLimiter,
  detectBookingFraud,
  createBooking,
);
router.get('/my-bookings', authenticateToken, resolveTenant, getMyBookings);

// Owner routes
router.get('/owner/bookings', authenticateToken, resolveTenant, getOwnerBookings);
router.get('/owner/stats', authenticateToken, resolveTenant, getBookingStats);

// Shared routes
router.post(
  '/cancellations/:cancellationId/refund-proposals',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.service_existing'),
  bookingLimiter,
  proposeBookingRefund,
);
router.post(
  '/refund-approvals/:approvalId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.service_existing'),
  bookingLimiter,
  decideBookingRefund,
);
router.get('/:id', authenticateToken, resolveTenant, getBookingById);
router.put('/:id/status', authenticateToken, resolveTenant, updateBookingStatus);
router.put('/:id/cancel', authenticateToken, resolveTenant, requireFeature('financial.payments.service_existing'), bookingLimiter, cancelBooking);

// New enhanced endpoints
router.post(
  '/:id/retry-payment',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.accept_new'),
  bookingLimiter,
  retryPayment,
);
router.get('/:id/history', authenticateToken, resolveTenant, getBookingHistory);
router.get('/:id/cancellation-eligibility', authenticateToken, resolveTenant, requireFeature('financial.payments.service_existing'), getCancellationEligibility);
router.get(
  '/:id/payment-retry-status',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.service_existing'),
  getPaymentRetryStatus,
);

export default router;
