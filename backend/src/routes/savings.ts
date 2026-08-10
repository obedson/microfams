import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { savingsController } from '../controllers/savingsController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { requireTenantPermission, resolveTenant } from '../middleware/tenant.js';

const router = Router();
const commandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, error: 'TOO_MANY_SAVINGS_COMMANDS' },
});

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/products', requireFeature('financial.savings.read'), savingsController.listProducts);
router.get('/enrolments', requireFeature('financial.savings.read'), savingsController.listEnrolments);
router.get('/enrolments/:enrolmentId/contributions',
  requireFeature('financial.savings.read'), savingsController.listContributions);
router.get('/enrolments/:enrolmentId/standing-orders',
  requireFeature('financial.savings.read'), savingsController.listStandingOrders);

router.post('/products',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.createProduct);
router.post('/products/:productId/submit',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.submitProduct);
router.post('/products/:productId/approve',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.approveProduct);
router.post('/products/:productId/enrolments',
  requireFeature('financial.savings.enrol'),
  commandLimiter,
  savingsController.enrol);
router.post('/enrolments/:enrolmentId/contributions',
  requireFeature('financial.savings.contribute'),
  commandLimiter,
  savingsController.contribute);
router.post('/enrolments/:enrolmentId/standing-orders',
  requireFeature('financial.savings.contribute'),
  commandLimiter,
  savingsController.createStandingOrder);
router.post('/standing-orders/:standingOrderId/pause',
  requireFeature('financial.savings.read'),
  commandLimiter,
  savingsController.transitionStandingOrder('pause'));
router.post('/standing-orders/:standingOrderId/resume',
  requireFeature('financial.savings.contribute'),
  commandLimiter,
  savingsController.transitionStandingOrder('resume'));
router.post('/standing-orders/:standingOrderId/cancel',
  requireFeature('financial.savings.read'),
  commandLimiter,
  savingsController.transitionStandingOrder('cancel'));

export default router;
