import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { savingsController } from '../controllers/savingsController.js';
import { savingsProviderCertificationController } from '../controllers/savingsProviderCertificationController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { requireSavingsProviderReady } from '../middleware/requireSavingsProviderReady.js';
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
router.get('/enrolments/:enrolmentId/accruals',
  requireFeature('financial.savings.read'), savingsController.listAccruals);
router.get('/enrolments/:enrolmentId/withdrawals',
  requireFeature('financial.savings.read'), savingsController.listWithdrawals);
router.get('/enrolments/:enrolmentId/statement',
  requireFeature('financial.savings.read'), savingsController.getStatement);
router.get('/reconciliation',
  requireFeature('financial.savings.service_existing'),
  requireTenantPermission('financial.reconciliation.manual'),
  savingsController.getReconciliation);
router.get('/accrual-batches',
  requireFeature('financial.savings.read'),
  requireTenantPermission('financial.savings.configure'),
  savingsController.listAccrualBatches);
router.get('/withdrawal-reviews',
  requireFeature('financial.savings.read'),
  requireTenantPermission('financial.savings.configure'),
  savingsController.listWithdrawalReviews);
router.get('/provider-certifications',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  savingsProviderCertificationController.list);
router.get('/provider-readiness',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  savingsProviderCertificationController.readiness);

router.post('/provider-certifications',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  commandLimiter,
  savingsProviderCertificationController.create);
router.post('/provider-certifications/:certificationId/scenarios',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  commandLimiter,
  savingsProviderCertificationController.recordScenario);
router.post('/provider-certifications/:certificationId/submit',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  commandLimiter,
  savingsProviderCertificationController.submit);
router.post('/provider-certifications/:certificationId/decide',
  requireFeature('financial.savings.configure'),
  requireTenantPermission('financial.activation.manage'),
  commandLimiter,
  savingsProviderCertificationController.decide);

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
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.approveProduct);
router.post('/products/:productId/enrolments',
  requireFeature('financial.savings.enrol'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.enrol);
router.post('/enrolments/:enrolmentId/contributions',
  requireFeature('financial.savings.contribute'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.contribute);
router.post('/enrolments/:enrolmentId/standing-orders',
  requireFeature('financial.savings.contribute'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.createStandingOrder);
router.post('/standing-orders/:standingOrderId/pause',
  requireFeature('financial.savings.read'),
  commandLimiter,
  savingsController.transitionStandingOrder('pause'));
router.post('/standing-orders/:standingOrderId/resume',
  requireFeature('financial.savings.contribute'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.transitionStandingOrder('resume'));
router.post('/standing-orders/:standingOrderId/cancel',
  requireFeature('financial.savings.read'),
  commandLimiter,
  savingsController.transitionStandingOrder('cancel'));
router.post('/accrual-batches',
  requireFeature('financial.savings.accrue'),
  requireTenantPermission('financial.savings.configure'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.calculateAccrual);
router.post('/accrual-batches/:batchId/approve',
  requireFeature('financial.savings.accrue'),
  requireTenantPermission('financial.savings.configure'),
  requireSavingsProviderReady,
  commandLimiter,
  savingsController.approveAccrual);
router.post('/accrual-batches/:batchId/reject',
  requireFeature('financial.savings.service_existing'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.rejectAccrual);
router.post('/enrolments/:enrolmentId/withdrawals',
  requireFeature('financial.savings.withdraw'),
  commandLimiter,
  savingsController.requestWithdrawal);
router.post('/withdrawals/:withdrawalId/approve',
  requireFeature('financial.savings.withdraw'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.approveWithdrawal);
router.post('/withdrawals/:withdrawalId/reject',
  requireFeature('financial.savings.service_existing'),
  requireTenantPermission('financial.savings.configure'),
  commandLimiter,
  savingsController.rejectWithdrawal);
router.post('/withdrawals/:withdrawalId/cancel',
  requireFeature('financial.savings.service_existing'),
  commandLimiter,
  savingsController.cancelWithdrawal);

export default router;
