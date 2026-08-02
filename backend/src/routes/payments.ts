import { Router } from 'express';
import { initializePayment, requestRefund, verifyPayment } from '../controllers/paymentOrchestrationController.js';
import { authenticateToken } from '../middleware/auth.js';
import { paymentLimiter } from '../middleware/rateLimiter.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { resolveTenant } from '../middleware/tenant.js';
import { groupAdmissionController } from '../controllers/groupAdmissionController.js';

const router = Router();

router.post(
  '/initialize',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.accept_new'),
  requireFeature('booking.settlements.create'),
  paymentLimiter,
  initializePayment,
);
router.get('/verify/:reference', requireFeature('financial.payments.service_existing'), verifyPayment);
router.post(
  '/:paymentId/refunds',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.service_existing'),
  paymentLimiter,
  requestRefund,
);

router.post('/initialize-group', authenticateToken, resolveTenant,
  requireFeature('groups.membership.manage'), requireFeature('financial.payments.accept_new'),
  paymentLimiter, groupAdmissionController.initializePayment);

export default router;
