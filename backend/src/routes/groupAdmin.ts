import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { groupAdminController } from '../controllers/groupAdminController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { groupGovernanceController } from '../controllers/groupGovernanceController.js';
import { groupInvitationController } from '../controllers/groupInvitationController.js';

const router = Router();
const invitationCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  message: { error: 'GROUP_INVITATION_RATE_LIMITED' },
});

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/:id/admin/dashboard', groupAdminController.getAdminDashboard);
router.post('/:id/invitations', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.create);
router.post('/:id/invitations/accept', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.accept);
router.get('/:id/invitations', requireFeature('groups.membership.manage'), groupInvitationController.list);
router.post('/:id/invitations/:invitationId/revoke', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.revoke);
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
