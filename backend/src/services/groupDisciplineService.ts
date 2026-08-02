import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';
import {
  GroupDisciplineAction,
  GroupDisciplineAppealOutcome,
} from '../domains/groups/disciplineRules.js';

export interface GroupDisciplineContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupDisciplineContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

const publicCaseFields = [
  'id', 'organization_id', 'group_id', 'membership_id', 'target_user_id',
  'constitution_id', 'proposed_action', 'state', 'reason_code', 'public_notice',
  'notice_issued_at', 'response_due_at', 'appeal_window_days', 'proposal_id',
  'decided_at', 'appeal_deadline', 'resolution_outcome', 'created_by',
  'created_at', 'updated_at',
].join(',');

const publicAppealFields = [
  'id', 'case_id', 'membership_id', 'appellant_id', 'state', 'grounds',
  'filed_at', 'decided_at', 'decided_by', 'decision_reason_code',
].join(',');

const mapCase = (row: any, canReview: boolean) => ({
  id: row.id,
  organizationId: row.organization_id,
  groupId: row.group_id,
  membershipId: row.membership_id,
  targetUserId: row.target_user_id,
  constitutionId: row.constitution_id,
  proposedAction: row.proposed_action,
  state: row.state,
  reasonCode: row.reason_code,
  publicNotice: row.public_notice,
  noticeIssuedAt: row.notice_issued_at,
  responseDueAt: row.response_due_at,
  appealWindowDays: row.appeal_window_days,
  proposalId: row.proposal_id,
  decidedAt: row.decided_at,
  appealDeadline: row.appeal_deadline,
  resolutionOutcome: row.resolution_outcome,
  createdBy: row.created_by,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
  ...(canReview ? { privateEvidenceRefs: row.private_evidence_refs } : {}),
});

export class GroupDisciplineService {
  private async access(context: GroupDisciplineContext, targetUserId?: string) {
    const [groupResult, tenantResult, memberResult] = await Promise.all([
      supabase.from('groups').select('id,creator_id').eq('id', context.groupId)
        .eq('organization_id', context.organizationId).maybeSingle(),
      supabase.from('organization_memberships').select('role,permissions')
        .eq('organization_id', context.organizationId).eq('user_id', context.actorId)
        .eq('status', 'active').maybeSingle(),
      supabase.from('group_members').select('id,user_id').eq('organization_id', context.organizationId)
        .eq('group_id', context.groupId).eq('user_id', context.actorId).maybeSingle(),
    ]);
    const error = groupResult.error ?? tenantResult.error ?? memberResult.error;
    if (error) throw error;
    if (!groupResult.data) return null;
    const permissions: string[] = tenantResult.data?.permissions ?? [];
    const canManage = tenantResult.data?.role === 'owner'
      || groupResult.data.creator_id === context.actorId
      || permissions.includes('groups.membership.discipline.manage')
      || permissions.includes('groups.governance.manage');
    const canDecideAppeal = tenantResult.data?.role === 'owner'
      || tenantResult.data?.role === 'admin'
      || permissions.includes('groups.membership.appeals.decide');
    const isTarget = targetUserId === context.actorId;
    return { canManage, canDecideAppeal, isTarget, isMember: !!memberResult.data };
  }

  async create(context: GroupDisciplineContext, memberId: string, input: {
    proposedAction: GroupDisciplineAction;
    reasonCode: string;
    publicNotice: string;
    privateEvidenceRefs: string[];
    responseDueAt: string;
    proposalClosesAt: string;
    appealWindowDays: number;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('create_group_member_discipline_case', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_membership_id: memberId,
      p_proposed_action: input.proposedAction,
      p_reason_code: input.reasonCode,
      p_public_notice: input.publicNotice,
      p_private_evidence_refs: input.privateEvidenceRefs,
      p_response_due_at: input.responseDueAt,
      p_proposal_closes_at: input.proposalClosesAt,
      p_appeal_window_days: input.appealWindowDays,
      p_correlation_id: correlationId(context, `discipline:${memberId}:create`, input.idempotencyKey),
    });
    if (error) throw error;
    return { caseId: data.case_id, proposalId: data.proposal_id };
  }

  async execute(context: GroupDisciplineContext, caseId: string, input: {
    expectedMembershipVersion: number;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('execute_group_member_discipline', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_case_id: caseId,
      p_expected_membership_version: input.expectedMembershipVersion,
      p_correlation_id: correlationId(context, `discipline:${caseId}:execute`, input.idempotencyKey),
    });
    if (error) throw error;
    return { membershipId: data.id, status: data.status, stateVersion: data.state_version };
  }

  async appeal(context: GroupDisciplineContext, caseId: string, input: {
    grounds: string;
    evidenceRefs: string[];
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('file_group_member_discipline_appeal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_case_id: caseId,
      p_grounds: input.grounds,
      p_evidence_refs: input.evidenceRefs,
      p_correlation_id: correlationId(context, `discipline:${caseId}:appeal`, input.idempotencyKey),
    });
    if (error) throw error;
    return { appealId: data };
  }

  async decideAppeal(context: GroupDisciplineContext, appealId: string, input: {
    outcome: GroupDisciplineAppealOutcome;
    reasonCode: string;
    decisionEvidenceRefs: string[];
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('decide_group_member_discipline_appeal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_appeal_id: appealId,
      p_outcome: input.outcome,
      p_reason_code: input.reasonCode,
      p_decision_evidence_refs: input.decisionEvidenceRefs,
      p_correlation_id: correlationId(context, `discipline-appeal:${appealId}:decide`, input.idempotencyKey),
    });
    if (error) throw error;
    return { membershipId: data.id, status: data.status, stateVersion: data.state_version };
  }

  async listForMember(context: GroupDisciplineContext, memberId: string, limit: number) {
    const { data: membership, error: membershipError } = await supabase.from('group_members')
      .select('user_id').eq('id', memberId).eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId).maybeSingle();
    if (membershipError) throw membershipError;
    if (!membership) return null;
    const access = await this.access(context, membership.user_id);
    if (!access || (!access.canManage && !access.isTarget)) return null;
    const fields = access.canManage ? `${publicCaseFields},private_evidence_refs` : publicCaseFields;
    const { data, error } = await supabase.from('group_member_discipline_cases').select(fields)
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId)
      .eq('membership_id', memberId).order('created_at', { ascending: false }).limit(limit);
    if (error) throw error;
    return (data ?? []).map((row: any) => mapCase(row, access.canManage));
  }

  async get(context: GroupDisciplineContext, caseId: string) {
    const { data: initial, error: initialError } = await supabase.from('group_member_discipline_cases')
      .select(publicCaseFields).eq('id', caseId)
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId).maybeSingle();
    if (initialError) throw initialError;
    if (!initial) return null;
    const initialRow = initial as any;
    const access = await this.access(context, initialRow.target_user_id);
    if (!access || (!access.canManage && !access.canDecideAppeal && !access.isTarget)) return null;
    const canReview = access.canManage || access.canDecideAppeal;
    const fields = canReview ? `${publicCaseFields},private_evidence_refs` : publicCaseFields;
    const [caseResult, appealResult] = await Promise.all([
      supabase.from('group_member_discipline_cases').select(fields).eq('id', caseId)
        .eq('organization_id', context.organizationId).eq('group_id', context.groupId).single(),
      supabase.from('group_member_discipline_appeals')
        .select(canReview ? `${publicAppealFields},evidence_refs,decision_evidence_refs` : publicAppealFields)
        .eq('organization_id', context.organizationId).eq('group_id', context.groupId)
        .eq('case_id', caseId).maybeSingle(),
    ]);
    if (caseResult.error) throw caseResult.error;
    if (appealResult.error) throw appealResult.error;
    const appeal: any = appealResult.data;
    return {
      ...mapCase(caseResult.data, canReview),
      appeal: appeal ? {
        id: appeal.id,
        caseId: appeal.case_id,
        membershipId: appeal.membership_id,
        appellantId: appeal.appellant_id,
        state: appeal.state,
        grounds: appeal.grounds,
        filedAt: appeal.filed_at,
        decidedAt: appeal.decided_at,
        decidedBy: appeal.decided_by,
        decisionReasonCode: appeal.decision_reason_code,
        ...(canReview ? {
          evidenceRefs: appeal.evidence_refs,
          decisionEvidenceRefs: appeal.decision_evidence_refs,
        } : {}),
      } : null,
    };
  }
}

export const groupDisciplineService = new GroupDisciplineService();
