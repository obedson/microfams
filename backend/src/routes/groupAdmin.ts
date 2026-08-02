import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { groupAdminController } from '../controllers/groupAdminController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { groupGovernanceController } from '../controllers/groupGovernanceController.js';
import { groupInvitationController } from '../controllers/groupInvitationController.js';
import { groupProposalController } from '../controllers/groupProposalController.js';
import { groupAdmissionController } from '../controllers/groupAdmissionController.js';
import { groupDisciplineController } from '../controllers/groupDisciplineController.js';

const router = Router();
const invitationCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  message: { error: 'GROUP_INVITATION_RATE_LIMITED' },
});
const proposalCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  message: { error: 'GROUP_PROPOSAL_RATE_LIMITED' },
});

router.use(authenticateToken as any);
router.use(resolveTenant);

router.get('/:id/admin/dashboard', groupAdminController.getAdminDashboard);
router.post('/:id/invitations', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.create);
router.post('/:id/invitations/accept', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.accept);
router.get('/:id/invitations', requireFeature('groups.membership.manage'), groupInvitationController.list);
router.post('/:id/invitations/:invitationId/revoke', invitationCommandLimiter, requireFeature('groups.membership.manage'), groupInvitationController.revoke);
router.get('/:id/proposals', requireFeature('groups.governance.manage'), groupProposalController.list);
router.get('/:id/proposals/:proposalId', requireFeature('groups.governance.manage'), groupProposalController.get);
router.post('/:id/proposals', proposalCommandLimiter, requireFeature('groups.governance.manage'), groupProposalController.create);
router.post('/:id/proposals/:proposalId/open', proposalCommandLimiter, requireFeature('groups.governance.manage'), groupProposalController.open);
router.post('/:id/proposals/:proposalId/votes', proposalCommandLimiter, requireFeature('groups.governance.manage'), groupProposalController.vote);
router.post('/:id/proposals/:proposalId/close', proposalCommandLimiter, requireFeature('groups.governance.manage'), groupProposalController.close);
router.post('/:id/proposals/:proposalId/cancel', proposalCommandLimiter, requireFeature('groups.governance.manage'), groupProposalController.cancel);
router.get('/:id/entry-requirements/current', requireFeature('groups.membership.manage'), groupAdmissionController.getCurrentRequirements);
router.post('/:id/entry-requirements/initial', proposalCommandLimiter, requireFeature('groups.membership.manage'), groupAdmissionController.adoptInitial);
router.get('/:id/members/:memberId/admission', requireFeature('groups.membership.manage'), groupAdmissionController.getStatus);
router.post('/:id/members/:memberId/admission/execute', proposalCommandLimiter, requireFeature('groups.membership.manage'), groupAdmissionController.execute);
router.get('/:id/members/:memberId/discipline-cases', groupDisciplineController.listForMember);
router.post(
  '/:id/members/:memberId/discipline-cases',
  proposalCommandLimiter,
  requireFeature('groups.membership.manage'),
  requireFeature('groups.governance.manage'),
  groupDisciplineController.create,
);
router.get('/:id/discipline-cases/:caseId', groupDisciplineController.get);
router.post(
  '/:id/discipline-cases/:caseId/execute',
  proposalCommandLimiter,
  requireFeature('groups.membership.manage'),
  requireFeature('groups.governance.manage'),
  groupDisciplineController.execute,
);
// Appeals are a servicing right, so filing and decisions remain available after acquisition flags change.
router.post('/:id/discipline-cases/:caseId/appeals', proposalCommandLimiter, groupDisciplineController.appeal);
router.post('/:id/discipline-appeals/:appealId/decision', proposalCommandLimiter, groupDisciplineController.decideAppeal);
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
router.get('/:id/member/dashboard', groupAdminController.getMemberDashboard);

export default router;
