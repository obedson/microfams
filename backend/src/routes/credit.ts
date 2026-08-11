import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { loanProductController } from '../controllers/loanProductController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { requireTenantPermission, resolveTenant } from '../middleware/tenant.js';

const router = Router();
const commandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, error: 'TOO_MANY_LOAN_PRODUCT_COMMANDS' },
});

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/products', requireFeature('financial.loans.read'), loanProductController.listActive);
router.get('/admin/products', requireFeature('financial.loans.configure'),
  requireTenantPermission('financial.loans.configure'), loanProductController.listGoverned);
router.post('/products', requireFeature('financial.loans.configure'),
  requireTenantPermission('financial.loans.configure'), commandLimiter, loanProductController.create);
router.post('/products/:productId/versions', requireFeature('financial.loans.configure'),
  requireTenantPermission('financial.loans.configure'), commandLimiter, loanProductController.revise);
router.post('/products/:productId/submit', requireFeature('financial.loans.configure'),
  requireTenantPermission('financial.loans.configure'), commandLimiter, loanProductController.submit);
router.post('/products/:productId/approve', requireFeature('financial.loans.configure'),
  requireTenantPermission('financial.loans.configure'), commandLimiter, loanProductController.approve);

export default router;
