import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { validate } from '../middleware/validate.js';
import { contributionSettingsSchema, makePaymentSchema } from '../utils/validation.js';
import * as contributionController from '../controllers/contributionController.js';
import { resolveTenant } from '../middleware/tenant.js';

const router = Router();

// Rate limiters
const paymentLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10,
  message: { error: 'Too many payment attempts, please try again later' }
});

// Settings
router.post('/groups/:id/contributions/settings', authenticateToken, resolveTenant, validate(contributionSettingsSchema), contributionController.updateSettings);
router.get('/groups/:id/contributions/settings', authenticateToken, resolveTenant, contributionController.getSettings);

// Cycles
router.post('/groups/:id/contributions/cycles', authenticateToken, resolveTenant, contributionController.createCycle);
router.get('/groups/:id/contributions/cycles/current', authenticateToken, resolveTenant, contributionController.getCurrentCycle);
router.get('/groups/:id/contributions/cycles/:cycleId', authenticateToken, resolveTenant, contributionController.getCycleDetails);

// Payments
router.post('/contributions/:id/pay', authenticateToken, resolveTenant, paymentLimiter, validate(makePaymentSchema), contributionController.makePayment);
router.get('/contributions/:id', authenticateToken, resolveTenant, contributionController.getContributionById);
router.get('/contributions/:id/penalty', authenticateToken, resolveTenant, contributionController.getPenalty);
router.get('/contributions/my-history', authenticateToken, resolveTenant, contributionController.getMyHistory);

// Admin actions
router.post('/contributions/members/:memberId/suspend', authenticateToken, resolveTenant, contributionController.suspendMember);
router.post('/contributions/members/:memberId/expel', authenticateToken, resolveTenant, contributionController.expelMember);

// Group Booking Integration
router.get('/user/group-funds', authenticateToken, resolveTenant, contributionController.getUserGroupFunds);
router.get('/groups/:groupId/booking-discount', authenticateToken, resolveTenant, contributionController.calculateGroupDiscount);
router.post('/bookings/pay-with-group-funds', authenticateToken, resolveTenant, contributionController.processGroupFundPayment);
router.post('/groups/propose-admin-change', authenticateToken, resolveTenant, contributionController.proposeAdminChange);
router.post('/groups/consensus-requests/:requestId/vote', authenticateToken, resolveTenant, contributionController.voteOnConsensusRequest);

export default router;
