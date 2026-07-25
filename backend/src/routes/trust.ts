import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { trustController } from '../controllers/trustController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { suspendedAccountRecoveryController } from '../controllers/suspendedAccountRecoveryController.js';

const router = Router();
const recoveryLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 5, standardHeaders: true, legacyHeaders: false });

router.post('/recovery/request', recoveryLimiter, requireFeature('trust.suspended_account_recovery'), suspendedAccountRecoveryController.request);
router.get('/recovery/status', recoveryLimiter, requireFeature('trust.suspended_account_recovery'), suspendedAccountRecoveryController.inspect);
router.post('/recovery/appeals', recoveryLimiter, requireFeature('trust.suspended_account_recovery'), suspendedAccountRecoveryController.fileAppeal);

router.use(authenticateToken);
router.get('/self/status', trustController.getSelfStatus);
router.get('/self/decisions', trustController.listSelfDecisions);
router.post('/self/appeals', requireFeature('trust.appeals'), trustController.fileSelfAppeal);

router.post(
  '/members/:membershipId/suspend',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  requireFeature('trust.suspensions'),
  trustController.suspendMembership,
);
router.post(
  '/members/:membershipId/resume',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  trustController.resumeMembership,
);

export default router;
