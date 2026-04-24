import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { validate } from '../middleware/validate.js';
import { contributionSettingsSchema, makePaymentSchema } from '../utils/validation.js';
import * as contributionController from '../controllers/contributionController.js';

const router = Router();

// Rate limiters
const paymentLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10,
  message: { error: 'Too many payment attempts, please try again later' }
});

// Settings
router.post('/groups/:id/contributions/settings', authenticateToken, validate(contributionSettingsSchema), contributionController.updateSettings);
router.get('/groups/:id/contributions/settings', authenticateToken, contributionController.getSettings);

// Cycles
router.post('/groups/:id/contributions/cycles', authenticateToken, contributionController.createCycle);
router.get('/groups/:id/contributions/cycles/current', authenticateToken, contributionController.getCurrentCycle);
router.get('/groups/:id/contributions/cycles/:cycleId', authenticateToken, contributionController.getCycleDetails);

// Payments
router.post('/contributions/:id/pay', authenticateToken, paymentLimiter, validate(makePaymentSchema), contributionController.makePayment);
router.get('/contributions/:id', authenticateToken, contributionController.getContributionById);
router.get('/contributions/:id/penalty', authenticateToken, contributionController.getPenalty);
router.get('/contributions/my-history', authenticateToken, contributionController.getMyHistory);

// Admin actions
router.post('/contributions/members/:memberId/suspend', authenticateToken, contributionController.suspendMember);
router.post('/contributions/members/:memberId/expel', authenticateToken, contributionController.expelMember);

// Group Booking Integration
router.get('/user/group-funds', authenticateToken, contributionController.getUserGroupFunds);
router.get('/groups/:groupId/booking-discount', authenticateToken, contributionController.calculateGroupDiscount);
router.post('/bookings/pay-with-group-funds', authenticateToken, contributionController.processGroupFundPayment);
router.post('/groups/propose-admin-change', authenticateToken, contributionController.proposeAdminChange);
router.post('/groups/consensus-requests/:requestId/vote', authenticateToken, contributionController.voteOnConsensusRequest);

export default router;
