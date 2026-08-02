import { thresholdCount } from './constitutionRules.js';

export const GROUP_PROPOSAL_TYPES = [
  'constitution_amendment',
  'membership_action',
  'office_appointment',
  'office_removal',
  'treasury_disbursement',
  'contribution_rule',
  'project',
  'committee_mandate',
  'shared_asset_action',
  'document_publication',
  'group_closure',
  'ordinary',
] as const;

export const GROUP_VOTE_CHOICES = ['approve', 'reject', 'abstain'] as const;

export type GroupProposalType = typeof GROUP_PROPOSAL_TYPES[number];
export type GroupVoteChoice = typeof GROUP_VOTE_CHOICES[number];
export type GroupApprovalRule = 'majority_non_abstaining' | 'eligible_threshold';
export type GroupProposalDecision = 'approved' | 'rejected' | 'expired';

export interface ProposalTally {
  approvals: number;
  rejections: number;
  abstentions: number;
}

export interface ProposalDecisionInput extends ProposalTally {
  eligibleCount: number;
  quorumBps: number;
  approvalBps: number;
  approvalRule: GroupApprovalRule;
}

const assertCount = (value: number) => {
  if (!Number.isInteger(value) || value < 0) throw new Error('GROUP_VOTE_TALLY_INVALID');
};
export const decideProposal = (input: ProposalDecisionInput): GroupProposalDecision => {
  assertCount(input.approvals);
  assertCount(input.rejections);
  assertCount(input.abstentions);
  assertCount(input.eligibleCount);
  const participation = input.approvals + input.rejections + input.abstentions;
  if (participation > input.eligibleCount) throw new Error('GROUP_VOTE_TALLY_INVALID');
  if (participation < thresholdCount(input.eligibleCount, input.quorumBps)) return 'expired';
  if (input.approvalRule === 'majority_non_abstaining') {
    return input.approvals > input.rejections ? 'approved' : 'rejected';
  }
  return input.approvals >= thresholdCount(input.eligibleCount, input.approvalBps)
    ? 'approved'
    : 'rejected';
};
