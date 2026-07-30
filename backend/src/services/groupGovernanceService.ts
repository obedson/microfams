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
}

export const groupGovernanceService = new GroupGovernanceService();
