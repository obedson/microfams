import { Router } from 'express';
import { groupAdminController } from '../controllers/groupAdminController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { groupGovernanceController } from '../controllers/groupGovernanceController.js';

const router = Router();

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/:id/admin/dashboard', groupAdminController.getAdminDashboard);
router.get(
  '/:id/governance-setup',
  requireFeature('groups.governance.manage'),
  groupGovernanceController.getSetup,
);
router.post(
  '/:id/constitutions/initial',
  requireFeature('groups.governance.manage'),
  groupGovernanceController.adoptInitial,
);
router.post(
  '/:id/offices/:officeKey/appointments',
  requireFeature('groups.governance.manage'),
  groupGovernanceController.appointInitialOffice,
);
router.post(
  '/:id/activate',
  requireFeature('groups.governance.manage'),
  groupGovernanceController.activate,
);
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
