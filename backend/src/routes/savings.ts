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

export default router;
