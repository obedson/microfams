import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { validate } from '../middleware/validate.js';
import { contributionSettingsSchema, makePaymentSchema } from '../utils/validation.js';
import * as contributionController from '../controllers/contributionController.js';
import { resolveTenant } from '../middleware/tenant.js';

const router = Router();
router.use(authenticateToken, resolveTenant);

// Rate limiters
const paymentLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10,
  message: { error: 'Too many payment attempts, please try again later' }
});

// Settings
router.post('/groups/:id/contributions/settings', validate(contributionSettingsSchema), contributionController.updateSettings);
router.get('/groups/:id/contributions/settings', contributionController.getSettings);

// Cycles
router.post('/groups/:id/contributions/cycles', contributionController.createCycle);
router.get('/groups/:id/contributions/cycles/current', contributionController.getCurrentCycle);
router.get('/groups/:id/contributions/cycles/:cycleId', contributionController.getCycleDetails);

// Payments
router.post('/contributions/:id/pay', paymentLimiter, validate(makePaymentSchema), contributionController.makePayment);
router.get('/contributions/:id', contributionController.getContributionById);
router.get('/contributions/:id/penalty', contributionController.getPenalty);
router.get('/contributions/my-history', contributionController.getMyHistory);

// Admin actions
router.post('/contributions/members/:memberId/suspend', contributionController.suspendMember);
router.post('/contributions/members/:memberId/expel', contributionController.expelMember);

// Group Booking Integration
router.get('/user/group-funds', contributionController.getUserGroupFunds);
router.get('/groups/:groupId/booking-discount', contributionController.calculateGroupDiscount);
router.post('/bookings/pay-with-group-funds', contributionController.processGroupFundPayment);
router.post('/groups/propose-admin-change', contributionController.proposeAdminChange);
router.post('/groups/consensus-requests/:requestId/vote', contributionController.voteOnConsensusRequest);

export default router;
