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
import {
  addBookingDisputeEvidence,
  getBookingDisputeTimeline,
  openBookingDispute,
} from '../controllers/bookingDisputeController.js';
import {
  decideBookingDisputeResponseRule,
  getBookingDisputeResolutionCase,
  proposeBookingDisputeResolution,
  proposeBookingDisputeResponseRule,
  transitionBookingDispute,
} from '../controllers/bookingDisputeResolutionController.js';
import { decideBookingRefund, proposeBookingRefund } from '../controllers/bookingRefundController.js';
import {
  decideBookingRecoveryAction,
  decideBookingRecoveryOffsetAgreement,
  proposeBookingRecoveryAction,
  proposeBookingRecoveryOffsetAgreement,
} from '../controllers/bookingRecoveryController.js';
import {
  decideBookingFinancialRule,
  getBookingFinancialRules,
  getBookingSettlement,
  proposeBookingFeeRule,
  proposeBookingSettlementRule,
  releaseBookingSettlement,
} from '../controllers/bookingSettlementController.js';
import {
  cancelBookingSupplierPayout,
  createBookingSupplierPayout,
  decideBookingPayoutBeneficiary,
  decideBookingPayoutChangeRule,
  listBookingPayoutBeneficiaries,
  proposeBookingPayoutChangeRule,
  registerBookingPayoutBeneficiary,
  syncBookingSupplierPayout,
} from '../controllers/bookingSupplierPayoutController.js';
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
  '/disputes/:disputeId/evidence',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  bookingLimiter,
  addBookingDisputeEvidence,
);
router.post(
  '/disputes/:disputeId/transitions',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  bookingLimiter,
  transitionBookingDispute,
);
router.post(
  '/disputes/:disputeId/resolution-proposals',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  bookingLimiter,
  proposeBookingDisputeResolution,
);
router.get(
  '/disputes/:disputeId/resolution',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  getBookingDisputeResolutionCase,
);
router.post(
  '/dispute-response-rules',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  bookingLimiter,
  proposeBookingDisputeResponseRule,
);
router.post(
  '/dispute-response-rule-approvals/:ruleId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  bookingLimiter,
  decideBookingDisputeResponseRule,
);
router.post(
  '/:id/disputes',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.open'),
  bookingLimiter,
  openBookingDispute,
);
router.get(
  '/:id/disputes',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.disputes.service_existing'),
  getBookingDisputeTimeline,
);
router.get(
  '/payout-beneficiaries',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  listBookingPayoutBeneficiaries,
);
router.post(
  '/payout-beneficiaries',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payouts.create'),
  bookingLimiter,
  registerBookingPayoutBeneficiary,
);
router.post(
  '/payout-beneficiaries/:beneficiaryId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payouts.create'),
  bookingLimiter,
  decideBookingPayoutBeneficiary,
);
router.post(
  '/payout-destination-change-rules',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payouts.create'),
  bookingLimiter,
  proposeBookingPayoutChangeRule,
);
router.post(
  '/payout-destination-change-rule-approvals/:ruleId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payouts.create'),
  bookingLimiter,
  decideBookingPayoutChangeRule,
);
router.post(
  '/settlement-releases/:releaseId/payouts',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.create'),
  bookingLimiter,
  createBookingSupplierPayout,
);
router.post(
  '/supplier-payouts/:payoutId/sync',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  syncBookingSupplierPayout,
);
router.post(
  '/supplier-payouts/:payoutId/cancel',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  cancelBookingSupplierPayout,
);
router.post(
  '/recovery-offset-agreements',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  proposeBookingRecoveryOffsetAgreement,
);
router.post(
  '/recovery-offset-agreements/:agreementId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  decideBookingRecoveryOffsetAgreement,
);
router.post(
  '/recovery-cases/:caseId/actions',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  proposeBookingRecoveryAction,
);
router.post(
  '/recovery-actions/:actionId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  requireFeature('financial.payouts.service_existing'),
  bookingLimiter,
  decideBookingRecoveryAction,
);
router.post(
  '/refund-approvals/:approvalId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.service_existing'),
  bookingLimiter,
  decideBookingRefund,
);
router.get(
  '/settlement-rules',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  getBookingFinancialRules,
);
router.post(
  '/settlement-rules',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  bookingLimiter,
  proposeBookingSettlementRule,
);
router.post(
  '/fee-rules',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  bookingLimiter,
  proposeBookingFeeRule,
);
router.post(
  '/settlement-rule-approvals/:approvalId/decision',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  bookingLimiter,
  decideBookingFinancialRule,
);
router.get(
  '/:id/settlement',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  getBookingSettlement,
);
router.post(
  '/:id/settlement/release',
  authenticateToken,
  resolveTenant,
  requireFeature('booking.settlements.service_existing'),
  bookingLimiter,
  releaseBookingSettlement,
);
router.get('/:id', authenticateToken, resolveTenant, getBookingById);
router.put('/:id/status', authenticateToken, resolveTenant, requireFeature('booking.lifecycle.manage'), bookingLimiter, updateBookingStatus);
router.put('/:id/cancel', authenticateToken, resolveTenant, requireFeature('financial.payments.service_existing'), bookingLimiter, cancelBooking);

// New enhanced endpoints
router.post(
  '/:id/retry-payment',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.accept_new'),
  requireFeature('booking.settlements.create'),
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
