import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { loanApplicationController } from '../controllers/loanApplicationController.js';
import { loanDelinquencyController } from '../controllers/loanDelinquencyController.js';
import { loanDisbursementController } from '../controllers/loanDisbursementController.js';
import { loanOfferController } from '../controllers/loanOfferController.js';
import { loanProductController } from '../controllers/loanProductController.js';
import { loanRepaymentController } from '../controllers/loanRepaymentController.js';
import { loanRepaymentReversalController } from '../controllers/loanRepaymentReversalController.js';
import { loanScheduleController } from '../controllers/loanScheduleController.js';
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
const applicationLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, error: 'TOO_MANY_LOAN_APPLICATION_COMMANDS' },
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

router.get('/applications', requireFeature('financial.loans.read'), loanApplicationController.list);
router.get('/admin/applications', requireFeature('financial.loans.read'),
  requireTenantPermission('financial.loans.review'), loanApplicationController.list);
router.post('/applications', requireFeature('financial.loans.originate'),
  applicationLimiter, loanApplicationController.create);
router.post('/applications/:applicationId/submit', requireFeature('financial.loans.originate'),
  applicationLimiter, loanApplicationController.submit);
router.post('/applications/:applicationId/adverse-review', requireFeature('financial.loans.service_existing'),
  applicationLimiter, loanApplicationController.requestAdverseReview);
router.post('/applications/:applicationId/withdraw', requireFeature('financial.loans.service_existing'),
  applicationLimiter, loanApplicationController.withdraw);
router.post('/admin/applications/:applicationId/adverse-review/decide', requireFeature('financial.loans.service_existing'),
  requireTenantPermission('financial.loans.review'), applicationLimiter, loanApplicationController.decideAdverseReview);
router.post('/admin/applications/:applicationId/offers', requireFeature('financial.loans.originate'),
  requireTenantPermission('financial.loans.review'), applicationLimiter, loanOfferController.issue);
router.post('/admin/applications/:applicationId/decline', requireFeature('financial.loans.originate'),
  requireTenantPermission('financial.loans.review'), applicationLimiter, loanOfferController.decline);
router.post('/applications/:applicationId/offers/:offerId/accept', requireFeature('financial.loans.originate'),
  applicationLimiter, loanOfferController.accept);
router.post('/admin/applications/:applicationId/offers/:offerId/expire', requireFeature('financial.loans.service_existing'),
  requireTenantPermission('financial.loans.review'), applicationLimiter, loanOfferController.expire);
router.post('/admin/applications/:applicationId/offers/:offerId/schedule',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.review'),
  applicationLimiter, loanScheduleController.generate);
router.post('/admin/applications/:applicationId/offers/:offerId/schedules/:scheduleId/conditions',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.disburse'),
  applicationLimiter, loanDisbursementController.initializeConditions);
router.post('/applications/:applicationId/conditions/:conditionId/evidence',
  requireFeature('financial.loans.service_existing'), applicationLimiter,
  loanDisbursementController.submitConditionEvidence);
router.post('/admin/applications/:applicationId/conditions/:conditionId/decision',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.disburse'),
  applicationLimiter, loanDisbursementController.decideCondition);
router.post('/applications/:applicationId/disbursement-destinations',
  requireFeature('financial.loans.service_existing'), applicationLimiter,
  loanDisbursementController.proposeDestination);
router.post('/admin/applications/:applicationId/disbursement-destinations/:destinationId/decision',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.disburse'),
  applicationLimiter, loanDisbursementController.decideDestination);
router.post('/admin/applications/:applicationId/disbursements',
  requireFeature('financial.loans.disburse'), requireTenantPermission('financial.loans.disburse'),
  applicationLimiter, loanDisbursementController.beginDisbursement);
router.post('/admin/applications/:applicationId/disbursements/:disbursementId/sync',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.disburse'),
  applicationLimiter, loanDisbursementController.syncDisbursement);
router.post('/admin/applications/:applicationId/contracts/:contractId/repayments',
  requireFeature('financial.loans.service_existing'),
  requireTenantPermission('financial.loans.service_existing'),
  applicationLimiter, loanRepaymentController.record);
router.post('/admin/applications/:applicationId/contracts/:contractId/repayments/:repaymentId/reversal',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.service_existing'),
  applicationLimiter, loanRepaymentReversalController.propose);
router.post('/admin/applications/:applicationId/contracts/:contractId/repayment-reversals/:reversalId/decision',
  requireFeature('financial.loans.service_existing'), requireTenantPermission('financial.loans.service_existing'),
  applicationLimiter, loanRepaymentReversalController.decide);
router.post('/admin/applications/:applicationId/contracts/:contractId/delinquency-assessments',
  requireFeature('financial.loans.service_existing'),
  requireTenantPermission('financial.loans.service_existing'),
  applicationLimiter, loanDelinquencyController.assess);

export default router;
