import { Router } from 'express';
import { trustController } from '../controllers/trustController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';

const router = Router();

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
