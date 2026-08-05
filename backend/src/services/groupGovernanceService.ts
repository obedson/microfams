import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';
import {
  ConstitutionRules,
  normalizeConstitutionRules,
} from '../domains/groups/constitutionRules.js';

export interface GroupGovernanceContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupGovernanceContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

export class GroupGovernanceService {
  async adoptInitialConstitution(
    context: GroupGovernanceContext,
    input: { name: string; rules: ConstitutionRules; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('adopt_initial_group_constitution', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_name: input.name,
      p_rules: normalizeConstitutionRules(input.rules),
      p_correlation_id: correlationId(context, 'constitution', input.idempotencyKey),
    });
    if (error) throw error;
    return { constitutionId: data };
  }

  async appointInitialOffice(
    context: GroupGovernanceContext,
    input: {
      officeKey: string;
      memberId: string;
      termEndsAt?: string;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('appoint_initial_group_office', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_office_key: input.officeKey,
      p_member_id: input.memberId,
      p_term_ends_at: input.termEndsAt ?? null,
      p_correlation_id: correlationId(
        context,
        `office:${input.officeKey}`,
        input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { assignmentId: data };
  }

  async activate(
    context: GroupGovernanceContext,
    input: { expectedLifecycleVersion: number; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('activate_group_with_constitution', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_expected_lifecycle_version: input.expectedLifecycleVersion,
      p_correlation_id: correlationId(context, 'activation', input.idempotencyKey),
    });
    if (error) throw error;
    return data;
  }

  async executeOfficeProposal(
    context: GroupGovernanceContext,
    proposalId: string,
    input: { expectedVersion: number; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('execute_group_office_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_expected_version: input.expectedVersion,
      p_correlation_id: correlationId(
        context, `office-proposal:${proposalId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return data;
  }

  async delegateOffice(
    context: GroupGovernanceContext,
    input: {
      officeKey: string; assignmentId: string; delegateMemberId: string;
      delegationEndsAt: string; idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('delegate_group_office', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_office_key: input.officeKey,
      p_assignment_id: input.assignmentId,
      p_delegate_member_id: input.delegateMemberId,
      p_delegation_ends_at: input.delegationEndsAt,
      p_correlation_id: correlationId(
        context, `office:${input.officeKey}:delegate`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { delegationId: data };
  }

  async endDelegation(
    context: GroupGovernanceContext,
    input: {
      officeKey: string; delegationId: string; reasonCode: string;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('end_group_office_delegation', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_office_key: input.officeKey,
      p_delegation_id: input.delegationId,
      p_reason_code: input.reasonCode,
      p_correlation_id: correlationId(
        context, `office:${input.officeKey}:end-delegation`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { delegationId: data };
  }

  async serviceExpiredOffices(
    context: GroupGovernanceContext,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('service_expired_group_offices', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(context, 'office:service-expired', input.idempotencyKey),
    });
    if (error) throw error;
    return data;
  }

  async getSetup(context: GroupGovernanceContext) {
    const [groupResult, tenantMembershipResult, groupMembershipResult] = await Promise.all([
      supabase.from('groups')
        .select('id, creator_id, lifecycle_state, lifecycle_version, current_constitution_id')
        .eq('id', context.groupId)
        .eq('organization_id', context.organizationId)
        .maybeSingle(),
      supabase.from('organization_memberships')
        .select('role, permissions')
        .eq('organization_id', context.organizationId)
        .eq('user_id', context.actorId)
        .eq('status', 'active')
        .maybeSingle(),
      supabase.from('group_members')
        .select('id')
        .eq('organization_id', context.organizationId)
        .eq('group_id', context.groupId)
        .eq('user_id', context.actorId)
        .eq('status', 'active')
        .maybeSingle(),
    ]);
    const group = groupResult.data;
    const groupError = groupResult.error
      ?? tenantMembershipResult.error
      ?? groupMembershipResult.error;
    if (groupError) throw groupError;
    if (!group) return null;
    const tenantMembership = tenantMembershipResult.data;
    const permissions = tenantMembership?.permissions ?? [];
    const canRead = group.creator_id === context.actorId
      || !!groupMembershipResult.data
      || tenantMembership?.role === 'owner'
      || permissions.includes('groups.governance.manage')
      || permissions.includes('groups.audit.read');
    if (!canRead) return null;
    const [constitutionResult, officesResult] = await Promise.all([
      group.current_constitution_id
        ? supabase.from('group_constitutions').select(
          'id, version, name, status, rules, effective_from',
        ).eq('id', group.current_constitution_id).eq(
          'organization_id', context.organizationId,
        ).maybeSingle()
        : Promise.resolve({ data: null, error: null }),
      supabase.from('group_office_assignments').select(
        'id, office_key, member_id, user_id, state, term_starts_at, term_ends_at',
      ).eq('group_id', context.groupId).eq(
        'organization_id', context.organizationId,
      ).in('state', ['active', 'delegated']),
    ]);
    if (constitutionResult.error) throw constitutionResult.error;
    if (officesResult.error) throw officesResult.error;
    return {
      group,
      constitution: constitutionResult.data,
      activeOffices: officesResult.data ?? [],
    };
  }

  async getOfficeLifecycle(context: GroupGovernanceContext) {
    const setup = await this.getSetup(context);
    if (!setup) return null;
    const [definitionsResult, assignmentsResult] = await Promise.all([
      supabase.from('group_office_definitions').select(
        'id,constitution_id,office_key,display_name,required_for_activation,permissions,term_required,max_term_days,delegation_allowed,max_delegation_days,incompatible_office_keys',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId),
      supabase.from('group_office_assignments').select(
        'id,constitution_id,office_key,member_id,user_id,state,term_starts_at,term_ends_at,delegated_from_assignment_id,appointed_by,appointment_basis,ended_at,end_reason_code,created_at',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId)
        .order('created_at', { ascending: false }).limit(500),
    ]);
    const error = definitionsResult.error ?? assignmentsResult.error;
    if (error) throw error;
    const now = Date.now();
    const assignments = assignmentsResult.data ?? [];
    const current = assignments.filter((assignment: any) => (
      ['active', 'delegated'].includes(assignment.state)
      && (!assignment.term_ends_at || new Date(assignment.term_ends_at).getTime() > now)
    ));
    const definitions = definitionsResult.data ?? [];
    return {
      ...setup,
      definitions,
      current,
      vacancies: definitions.filter((definition: any) => (
        !current.some((assignment: any) => assignment.office_key === definition.office_key)
      )).map((definition: any) => definition.office_key),
      history: assignments,
    };
  }
}

export const groupGovernanceService = new GroupGovernanceService();
