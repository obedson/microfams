import { Router } from 'express';
import { groupAdminController } from '../controllers/groupAdminController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';

const router = Router();

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/:id/admin/dashboard', groupAdminController.getAdminDashboard);
router.put(
  '/:id',
  requireFeature('groups.membership.manage'),
  groupAdminController.updateGroup,
);
router.post(
  '/:id/members/:memberId/vote',
  requireFeature('groups.governance.manage'),
  groupAdminController.castVote,
);
router.get('/:id/votes', groupAdminController.getVotes);
router.get('/:id/member/dashboard', groupAdminController.getMemberDashboard);

export default router;
