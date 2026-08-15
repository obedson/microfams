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
import { groupContributionController } from '../controllers/groupContributionController.js';
import { groupContributionCycleController } from '../controllers/groupContributionCycleController.js';
import { groupTreasuryController } from '../controllers/groupTreasuryController.js';
import { groupCommitteeController } from '../controllers/groupCommitteeController.js';
import { groupTreasuryEmergencyController } from '../controllers/groupTreasuryEmergencyController.js';

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
const contributionCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  message: { error: 'GROUP_CONTRIBUTION_RATE_LIMITED' },
});
const treasuryCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  message: { error: 'GROUP_TREASURY_RATE_LIMITED' },
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
router.post(
  '/:id/proposals/:proposalId/office-execution', proposalCommandLimiter,
  requireFeature('groups.governance.manage'), groupGovernanceController.executeOfficeProposal,
);
router.get(
  '/:id/offices/lifecycle',
  requireFeature('groups.governance.manage'),
  groupGovernanceController.getOfficeLifecycle,
);
router.post(
  '/:id/offices/service-expired', proposalCommandLimiter,
  requireFeature('groups.governance.manage'), groupGovernanceController.serviceExpired,
);
router.post(
  '/:id/offices/:officeKey/delegations', proposalCommandLimiter,
  requireFeature('groups.governance.manage'), groupGovernanceController.delegateOffice,
);
router.post(
  '/:id/offices/:officeKey/delegations/:assignmentId/end', proposalCommandLimiter,
  requireFeature('groups.governance.manage'), groupGovernanceController.endDelegation,
);
router.post(
  '/:id/proposals/:proposalId/contribution-execution', proposalCommandLimiter,
  requireFeature('groups.governance.manage'), groupContributionController.executeRuleProposal,
);
// Disclosure is a membership right: any active member may read the classified
// products and the terms in force, so these reads are not governance-gated.
router.get('/:id/contribution-products', groupContributionController.listProducts);
router.get('/:id/contribution-products/:productId', groupContributionController.getProduct);
router.get(
  '/:id/contribution-products/:productId/allocations',
  groupContributionController.listAllocations,
);
// Taking new contribution money is acquisition and gated accordingly.
router.post(
  '/:id/contribution-products/:productId/payments', contributionCommandLimiter,
  requireFeature('groups.contributions.accept_new'), groupContributionController.initializePayment,
);
// Allocating an already-captured payment is servicing: it must stay available
// when acquisition is switched off, or confirmed money strands unposted.
router.post(
  '/:id/contribution-products/:productId/allocations', contributionCommandLimiter,
  requireFeature('groups.contributions.service_existing'),
  groupContributionController.allocatePayment,
);
// Cycles: reads are a membership right for the same reason product reads are —
// a member must be able to see what they were billed and why.
router.get('/:id/contribution-cycles', groupContributionCycleController.listCycles);
router.get('/:id/contribution-cycles/:cycleId', groupContributionCycleController.getCycle);
// Opening a cycle bills members, so it is acquisition and governance-gated.
router.post(
  '/:id/contribution-cycles', contributionCommandLimiter,
  requireFeature('groups.contributions.accept_new'),
  requireFeature('groups.governance.manage'),
  groupContributionCycleController.openCycle,
);
// Adjusting an obligation and closing a cycle are servicing: they must remain
// available when acquisition is switched off, or an open cycle can never be
// reconciled or closed.
router.post(
  '/:id/contribution-obligations/:obligationId/adjustments', contributionCommandLimiter,
  requireFeature('groups.contributions.service_existing'),
  requireFeature('groups.governance.manage'),
  groupContributionCycleController.adjustObligation,
);
router.post(
  '/:id/contribution-cycles/:cycleId/transitions', contributionCommandLimiter,
  requireFeature('groups.contributions.service_existing'),
  requireFeature('groups.governance.manage'),
  groupContributionCycleController.transitionCycle,
);
router.post(
  '/:id/contribution-cycles/:cycleId/close', contributionCommandLimiter,
  requireFeature('groups.contributions.service_existing'),
  requireFeature('groups.governance.manage'),
  groupContributionCycleController.closeCycle,
);
router.post(
  '/:id/contribution-cycles/:cycleId/cancel', contributionCommandLimiter,
  requireFeature('groups.contributions.service_existing'),
  requireFeature('groups.governance.manage'),
  groupContributionCycleController.cancelCycle,
);
// Treasury: reads are a membership right. A member funds the treasury, so a
// member must be able to see what it holds, what is committed, and where it went.
router.get('/:id/treasury/available', groupTreasuryController.getAvailable);
router.get('/:id/treasury/budgets', groupTreasuryController.listBudgets);
router.get('/:id/treasury/disbursements', groupTreasuryController.listDisbursements);
router.get(
  '/:id/treasury/disbursements/:disbursementId', groupTreasuryController.getDisbursement,
);
router.get('/:id/treasury/reservations', groupTreasuryController.listReservations);
router.get('/:id/treasury/emergency-policy', groupTreasuryEmergencyController.getPolicy);
router.get('/:id/treasury/emergencies', groupTreasuryEmergencyController.list);
router.put(
  '/:id/treasury/emergency-policy', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryEmergencyController.configurePolicy,
);
router.post(
  '/:id/treasury/emergencies', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryEmergencyController.request,
);
router.post(
  '/:id/treasury/emergencies/:emergencyId/approve', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryEmergencyController.approve,
);
router.post(
  '/:id/treasury/emergencies/:emergencyId/ratify', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryEmergencyController.ratify,
);
// Activating a budget and requesting a spend create new exposure, so both are
// gated on acquisition as well as governance.
router.post(
  '/:id/treasury/budgets/:budgetId/activate', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.activateBudget,
);
router.post(
  '/:id/treasury/disbursements', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.requestDisbursement,
);
// Approving, executing, releasing, and reversing are servicing: they must stay
// available when acquisition is switched off, or funds reserved before the
// switch could never be paid out or returned to the available pool.
router.post(
  '/:id/treasury/disbursements/:disbursementId/approve', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.approveDisbursement,
);
router.post(
  '/:id/treasury/disbursements/:disbursementId/execute', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.executeDisbursement,
);
router.post(
  '/:id/treasury/disbursements/:disbursementId/release', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.releaseReservation,
);
router.post(
  '/:id/treasury/disbursements/:disbursementId/reverse', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.reverseDisbursement,
);
// GT-06B external provider disbursements. A verified beneficiary is the only
// off-platform destination the treasury will pay, so its registry sits beside
// the disbursement commands under the same limiter and gates. Reads stay a
// membership right — masks only, never the destination — like the balance above.
router.get('/:id/treasury/beneficiaries', groupTreasuryController.listBeneficiaries);
// Registering a destination and requesting an external spend both create new
// exposure, so both are gated on acquisition as well as governance.
router.post(
  '/:id/treasury/beneficiaries', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.registerBeneficiary,
);
router.post(
  '/:id/treasury/disbursements/external', treasuryCommandLimiter,
  requireFeature('groups.treasury.create_disbursement'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.requestExternalDisbursement,
);
// Verifying, rejecting, beginning, and syncing are servicing: they must remain
// available when acquisition is switched off, or a destination registered before
// the switch could never be verified and a payout in flight never reconciled.
router.post(
  '/:id/treasury/beneficiaries/:beneficiaryId/approve', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.approveBeneficiary,
);
router.post(
  '/:id/treasury/beneficiaries/:beneficiaryId/reject', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.rejectBeneficiary,
);
router.post(
  '/:id/treasury/disbursements/:disbursementId/begin', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.beginExternalDisbursement,
);
router.post(
  '/:id/treasury/disbursements/:disbursementId/sync', treasuryCommandLimiter,
  requireFeature('groups.treasury.service_existing'),
  requireFeature('groups.governance.manage'),
  groupTreasuryController.syncExternalPayout,
);
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

const committeeCommandLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  message: { error: 'GROUP_COMMITTEE_RATE_LIMITED' },
});

router.get(
  '/:id/committees',
  requireFeature('groups.governance.manage'), groupCommitteeController.getOverview,
);
router.post(
  '/:id/proposals/:proposalId/committee-execution', committeeCommandLimiter,
  requireFeature('groups.governance.manage'),
  groupCommitteeController.executeCommitteeProposal,
);
router.post(
  '/:id/committees/:committeeId/members', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.addMember,
);
router.post(
  '/:id/committee-memberships/:membershipId/end', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.endMembership,
);
router.post(
  '/:id/meetings', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.scheduleMeeting,
);
router.get(
  '/:id/meetings/:meetingId',
  requireFeature('groups.governance.manage'), groupCommitteeController.getMeeting,
);
router.post(
  '/:id/meetings/:meetingId/attendance', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.recordAttendance,
);
router.post(
  '/:id/meetings/:meetingId/hold', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.holdMeeting,
);
router.post(
  '/:id/meetings/:meetingId/cancel', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.cancelMeeting,
);
router.post(
  '/:id/meetings/:meetingId/minutes', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.draftMinutes,
);
router.post(
  '/:id/meeting-minutes/:minutesId/approve', committeeCommandLimiter,
  requireFeature('groups.governance.manage'), groupCommitteeController.approveMinutes,
);


export default router;
