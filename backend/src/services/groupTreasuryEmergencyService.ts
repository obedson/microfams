import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';

const correlationId = (_context: GroupTreasuryContext, command: string, key: string) =>
  randomUUID();

export interface EmergencyPolicyInput {
  enabled: boolean;
  capMinor: number;
  ratificationHours?: number;
  noticeDeadlineMinutes?: number;
}
export interface EmergencyInput {
  budgetId: string;
  beneficiaryKind: 'member' | 'group' | 'project';
  beneficiaryMemberId?: string | null;
  beneficiaryGroupId?: string | null;
  beneficiaryProjectId?: string | null;
  amountMinor: number;
  currency: string;
  purpose: string;
  emergencyReason: string;
  evidenceUri: string;
  idempotencyKey: string;
}
export class GroupTreasuryEmergencyService {
  async configurePolicy(context: GroupTreasuryContext, input: EmergencyPolicyInput) {
    const { data, error } = await supabase.rpc('configure_group_treasury_emergency_policy', {
      p_organization_id: context.organizationId, p_group_id: context.groupId, p_actor_id: context.actorId,
      p_enabled: input.enabled, p_cap_minor: input.capMinor,
      p_ratification_hours: input.ratificationHours ?? 72,
      p_notice_deadline_minutes: input.noticeDeadlineMinutes ?? 60,
      p_correlation_id: correlationId(context, 'emergency-policy', String(input.capMinor)),
    });
    if (error) throw error;
    return { policyId: data };
  }
  async getPolicy(context: GroupTreasuryContext) {
    const { data, error } = await supabase.from('group_treasury_emergency_policies')
      .select('id, group_id, constitution_id, enabled, cap_minor, minimum_approvers, ratification_hours, notice_deadline_minutes, updated_by, updated_at')
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId).maybeSingle();
    if (error) throw error;
    return data;
  }
  async request(context: GroupTreasuryContext, input: EmergencyInput) {
    const { data, error } = await supabase.rpc('request_group_treasury_emergency', {
      p_organization_id: context.organizationId, p_group_id: context.groupId, p_budget_id: input.budgetId,
      p_beneficiary_kind: input.beneficiaryKind, p_beneficiary_member_id: input.beneficiaryMemberId ?? null,
      p_beneficiary_group_id: input.beneficiaryGroupId ?? null, p_beneficiary_project_id: input.beneficiaryProjectId ?? null,
      p_amount_minor: input.amountMinor, p_currency: input.currency, p_purpose: input.purpose,
      p_emergency_reason: input.emergencyReason, p_evidence_uri: input.evidenceUri,
      p_requested_by: context.actorId, p_idempotency_key: input.idempotencyKey,
      p_correlation_id: correlationId(context, 'emergency-request', input.idempotencyKey),
    });
    if (error) throw error;
    return { emergencyId: data, state: 'requested' };
  }
  async approve(context: GroupTreasuryContext, emergencyId: string, idempotencyKey: string) {
    const { data, error } = await supabase.rpc('approve_group_treasury_emergency', {
      p_organization_id: context.organizationId, p_emergency_id: emergencyId, p_actor_id: context.actorId,
      p_correlation_id: correlationId(context, 'emergency-approve', emergencyId + ':' + idempotencyKey),
    });
    if (error) throw error;
    return { journalEntryId: data ?? null, firstApprovalRecorded: data == null };
  }
  async ratify(context: GroupTreasuryContext, emergencyId: string, idempotencyKey: string) {
    const { data, error } = await supabase.rpc('ratify_group_treasury_emergency', {
      p_organization_id: context.organizationId, p_emergency_id: emergencyId, p_actor_id: context.actorId,
      p_correlation_id: correlationId(context, 'emergency-ratify', emergencyId + ':' + idempotencyKey),
    });
    if (error) throw error;
    return { state: data };
  }
  async list(context: GroupTreasuryContext, state?: string) {
    let query = supabase.from('group_treasury_emergency_expenditures')
      .select('id, group_id, budget_id, beneficiary_kind, beneficiary_member_id, beneficiary_group_id, beneficiary_project_id, amount_minor, currency, purpose, emergency_reason, evidence_uri, state, requested_by, first_approver_id, second_approver_id, execution_journal_entry_id, ratification_proposal_id, ratification_due_at, notice_enqueued_at, approved_at, ratified_at, created_at')
      .eq('organization_id', context.organizationId).eq('group_id', context.groupId);
    if (state) query = query.eq('state', state);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return data ?? [];
  }
}
export default new GroupTreasuryEmergencyService();
