import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupProposalType, GroupVoteChoice } from '../domains/groups/proposalRules.js';

export interface GroupProposalContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupProposalContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

const proposalFields = [
  'id', 'organization_id', 'group_id', 'proposal_type', 'proposer_id',
  'constitution_id', 'public_summary', 'state', 'state_version', 'opens_at',
  'closes_at', 'opened_at', 'decided_at', 'result', 'created_at', 'updated_at',
].join(',');

const privateProposalFields = `${proposalFields},private_evidence_refs,execution_payload,conflict_user_ids`;

const publicProposal = (row: any) => ({
  id: row.id,
  organizationId: row.organization_id,
  groupId: row.group_id,
  proposalType: row.proposal_type,
  proposerId: row.proposer_id,
  constitutionId: row.constitution_id,
  publicSummary: row.public_summary,
  state: row.state,
  stateVersion: row.state_version,
  opensAt: row.opens_at,
  closesAt: row.closes_at,
  openedAt: row.opened_at,
  decidedAt: row.decided_at,
  result: row.result,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

export class GroupProposalService {
  private async reader(context: GroupProposalContext) {
    const [groupResult, tenantResult, memberResult] = await Promise.all([
      supabase.from('groups').select('id,creator_id').eq('id', context.groupId)
        .eq('organization_id', context.organizationId).maybeSingle(),
      supabase.from('organization_memberships').select('role,permissions')
        .eq('organization_id', context.organizationId).eq('user_id', context.actorId)
        .eq('status', 'active').maybeSingle(),
      supabase.from('group_members').select('id').eq('organization_id', context.organizationId)
        .eq('group_id', context.groupId).eq('user_id', context.actorId)
        .eq('status', 'active').eq('is_active', true).maybeSingle(),
    ]);
    const error = groupResult.error ?? tenantResult.error ?? memberResult.error;
    if (error) throw error;
    if (!groupResult.data) return null;
    const tenant = tenantResult.data;
    const permissions = tenant?.permissions ?? [];
    const canManage = tenant?.role === 'owner'
      || permissions.includes('groups.proposals.manage')
      || permissions.includes('groups.governance.manage');
    const canRead = canManage || permissions.includes('groups.audit.read')
      || groupResult.data.creator_id === context.actorId || !!memberResult.data;
    return canRead ? { canManage } : null;
  }

  async create(context: GroupProposalContext, input: {
    proposalType: GroupProposalType;
    publicSummary: string;
    privateEvidenceRefs: unknown[];
    executionPayload: Record<string, unknown>;
    conflictUserIds: string[];
    opensAt: string;
    closesAt: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('create_group_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_type: input.proposalType,
      p_public_summary: input.publicSummary,
      p_private_evidence_refs: input.privateEvidenceRefs,
      p_execution_payload: input.executionPayload,
      p_conflict_user_ids: input.conflictUserIds,
      p_opens_at: input.opensAt,
      p_closes_at: input.closesAt,
      p_correlation_id: correlationId(context, 'proposal:create', input.idempotencyKey),
    });
    if (error) throw error;
    return { proposalId: data };
  }

  async open(context: GroupProposalContext, proposalId: string, input: {
    expectedVersion: number; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('open_group_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_expected_version: input.expectedVersion,
      p_correlation_id: correlationId(context, `proposal:${proposalId}:open`, input.idempotencyKey),
    });
    if (error) throw error;
    return { snapshotId: data };
  }

  async vote(context: GroupProposalContext, proposalId: string, input: {
    choice: GroupVoteChoice; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('cast_group_proposal_vote', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_choice: input.choice,
      p_correlation_id: correlationId(context, `proposal:${proposalId}:vote`, input.idempotencyKey),
    });
    if (error) throw error;
    return { voteId: data };
  }

  async close(context: GroupProposalContext, proposalId: string, input: {
    expectedVersion: number; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('close_group_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_expected_version: input.expectedVersion,
      p_correlation_id: correlationId(context, `proposal:${proposalId}:close`, input.idempotencyKey),
    });
    if (error) throw error;
    return publicProposal(data);
  }

  async cancel(context: GroupProposalContext, proposalId: string, input: {
    expectedVersion: number; reasonCode: string; idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('cancel_group_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_expected_version: input.expectedVersion,
      p_reason_code: input.reasonCode,
      p_correlation_id: correlationId(context, `proposal:${proposalId}:cancel`, input.idempotencyKey),
    });
    if (error) throw error;
    return publicProposal(data);
  }

  async list(context: GroupProposalContext, limit: number) {
    const access = await this.reader(context);
    if (!access) return null;
    const { data, error } = await supabase.from('group_proposals').select(proposalFields)
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId)
      .order('created_at', { ascending: false }).limit(limit);
    if (error) throw error;
    return (data ?? []).map(publicProposal);
  }

  async get(context: GroupProposalContext, proposalId: string) {
    const access = await this.reader(context);
    if (!access) return null;
    const { data: proposal, error } = await supabase.from('group_proposals')
      .select(access.canManage ? privateProposalFields : proposalFields)
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId)
      .eq('id', proposalId).maybeSingle();
    if (error) throw error;
    if (!proposal) return null;
    const [snapshotResult, voteResult] = await Promise.all([
      supabase.from('group_voting_snapshots').select(
        'id,rule_kind,eligible_count,excluded_count,quorum_bps,quorum_count,approval_bps,approval_count,approval_rule,vote_change_allowed,created_at',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId)
        .eq('proposal_id', proposalId).maybeSingle(),
      supabase.from('group_vote_history').select('voter_id,choice,sequence,cast_at')
        .eq('organization_id', context.organizationId)
        .eq('group_id', context.groupId).eq('proposal_id', proposalId).eq('is_current', true),
    ]);
    if (snapshotResult.error) throw snapshotResult.error;
    if (voteResult.error) throw voteResult.error;
    const proposalRow = proposal as any;
    const tally = (voteResult.data ?? []).reduce((value, vote: any) => {
      const choice = vote.choice as GroupVoteChoice;
      value[choice] += 1;
      return value;
    }, { approve: 0, reject: 0, abstain: 0 } as Record<GroupVoteChoice, number>);
    const snapshot = snapshotResult.data as any;
    const ownVote = (voteResult.data ?? []).find(
      (vote: any) => vote.voter_id === context.actorId,
    ) as any;
    return {
      ...publicProposal(proposalRow),
      ...(access.canManage ? {
        privateEvidenceRefs: proposalRow.private_evidence_refs,
        executionPayload: proposalRow.execution_payload,
        conflictUserIds: proposalRow.conflict_user_ids,
      } : {}),
      snapshot: snapshot ? {
        id: snapshot.id,
        ruleKind: snapshot.rule_kind,
        eligibleCount: snapshot.eligible_count,
        excludedCount: snapshot.excluded_count,
        quorumBps: snapshot.quorum_bps,
        quorumCount: snapshot.quorum_count,
        approvalBps: snapshot.approval_bps,
        approvalCount: snapshot.approval_count,
        approvalRule: snapshot.approval_rule,
        voteChangeAllowed: snapshot.vote_change_allowed,
        createdAt: snapshot.created_at,
      } : null,
      tally,
      myVote: ownVote ? {
        choice: ownVote.choice,
        sequence: ownVote.sequence,
        castAt: ownVote.cast_at,
      } : null,
    };
  }
}

export const groupProposalService = new GroupProposalService();
