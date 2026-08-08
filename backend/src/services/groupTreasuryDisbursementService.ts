import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';
import {
  assertFundsAvailable,
  assertSeparationOfDuties,
  validateDisbursementRequest,
  validateReleaseReasonCode,
} from '../domains/groups/treasuryDisbursementRules.js';

export interface GroupTreasuryContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupTreasuryContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

const DISBURSEMENT_COLUMNS = 'id, budget_id, constitution_id, proposal_id, channel, beneficiary_kind, beneficiary_member_id, beneficiary_user_id, beneficiary_group_id, beneficiary_project_id, amount_minor, currency, purpose, evidence_uri, execute_from, execute_until, state, requested_by, final_checker_id, approver_count, available_minor_at_approval, quorum_bps_applied, approval_bps_applied, threshold_basis, reservation_id, execution_journal_entry_id, reversal_journal_entry_id, approved_at, executed_at, settled_state_at, created_at';

const BUDGET_COLUMNS = 'id, constitution_id, budget_key, display_name, purpose, currency, ceiling_minor, committed_minor, disbursed_minor, state, low_value_band_minor, low_value_quorum_bps, low_value_approval_bps, period_start, period_end, opened_at, closed_at';

const RESERVATION_COLUMNS = 'id, budget_id, disbursement_id, source_account_id, amount_minor, currency, state, available_minor_at_reserve, expires_at, consumed_journal_entry_id, consumed_at, released_at, expired_at, release_reason_code';

const publicDisbursement = (row: any) => row && ({
  id: row.id,
  budgetId: row.budget_id,
  constitutionId: row.constitution_id,
  proposalId: row.proposal_id,
  channel: row.channel,
  beneficiaryKind: row.beneficiary_kind,
  beneficiaryMemberId: row.beneficiary_member_id,
  beneficiaryUserId: row.beneficiary_user_id,
  beneficiaryGroupId: row.beneficiary_group_id,
  beneficiaryProjectId: row.beneficiary_project_id,
  amountMinor: row.amount_minor,
  currency: row.currency,
  purpose: row.purpose,
  evidenceUri: row.evidence_uri,
  executeFrom: row.execute_from,
  executeUntil: row.execute_until,
  state: row.state,
  // Maker and checker are surfaced separately so a reviewer can see the two
  // distinct people behind any executed payment (clause 3).
  requestedBy: row.requested_by,
  finalCheckerId: row.final_checker_id,
  approverCount: row.approver_count,
  // Clause 5: what was true when the decision was taken, kept beside the row so
  // the approval stays explainable after balances move on.
  availableMinorAtApproval: row.available_minor_at_approval,
  quorumBpsApplied: row.quorum_bps_applied,
  approvalBpsApplied: row.approval_bps_applied,
  thresholdBasis: row.threshold_basis,
  reservationId: row.reservation_id,
  executionJournalEntryId: row.execution_journal_entry_id,
  reversalJournalEntryId: row.reversal_journal_entry_id,
  approvedAt: row.approved_at,
  executedAt: row.executed_at,
  settledStateAt: row.settled_state_at,
  createdAt: row.created_at,
});

const publicBudget = (row: any) => row && ({
  id: row.id,
  constitutionId: row.constitution_id,
  budgetKey: row.budget_key,
  displayName: row.display_name,
  purpose: row.purpose,
  currency: row.currency,
  ceilingMinor: row.ceiling_minor,
  committedMinor: row.committed_minor,
  disbursedMinor: row.disbursed_minor,
  // Derived rather than stored, so it cannot drift from the two figures it
  // sits between.
  remainingMinor:
    Number(row.ceiling_minor) - Number(row.committed_minor) - Number(row.disbursed_minor),
  state: row.state,
  lowValueBandMinor: row.low_value_band_minor,
  lowValueQuorumBps: row.low_value_quorum_bps,
  lowValueApprovalBps: row.low_value_approval_bps,
  periodStart: row.period_start,
  periodEnd: row.period_end,
  openedAt: row.opened_at,
  closedAt: row.closed_at,
});

const publicReservation = (row: any) => row && ({
  id: row.id,
  budgetId: row.budget_id,
  disbursementId: row.disbursement_id,
  sourceAccountId: row.source_account_id,
  amountMinor: row.amount_minor,
  currency: row.currency,
  state: row.state,
  availableMinorAtReserve: row.available_minor_at_reserve,
  expiresAt: row.expires_at,
  consumedJournalEntryId: row.consumed_journal_entry_id,
  consumedAt: row.consumed_at,
  releasedAt: row.released_at,
  expiredAt: row.expired_at,
  releaseReasonCode: row.release_reason_code,
});

/**
 * GT-06A treasury operations. Every state change goes through a database
 * function so the disbursement, its reservation, and the journal move in one
 * transaction; this layer validates the caller's request and shapes the
 * response. Availability is read back from the engine rather than cached,
 * because a stale figure is what lets two approvals spend the same money.
 */
export class GroupTreasuryDisbursementService {
  /**
   * Funds available after existing reservations, derived from posted journals
   * rather than a mutable balance column (clause 2).
   */
  async getAvailableMinor(context: GroupTreasuryContext) {
    const { data, error } = await supabase.rpc('group_treasury_available_minor', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
    });
    if (error) throw error;
    return Number(data ?? 0);
  }

  async listBudgets(context: GroupTreasuryContext) {
    const { data, error } = await supabase
      .from('group_treasury_budgets')
      .select(BUDGET_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .order('budget_key', { ascending: true });
    if (error) throw error;
    return (data ?? []).map(publicBudget);
  }

  async activateBudget(
    context: GroupTreasuryContext,
    budgetId: string,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('activate_group_treasury_budget', {
      p_organization_id: context.organizationId,
      p_budget_id: budgetId,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-budget-activate:${budgetId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { budgetId: data };
  }

  /**
   * Raises a spending request against an approved proposal. The amount is
   * checked against funds available after existing reservations so an obviously
   * unfundable request is refused early, but the binding check is the one the
   * engine performs under lock at approval time (clause 2).
   */
  async requestDisbursement(
    context: GroupTreasuryContext,
    input: {
      budgetId: string;
      proposalId: string;
      beneficiaryKind: string;
      beneficiaryMemberId?: string | null;
      beneficiaryGroupId?: string | null;
      beneficiaryProjectId?: string | null;
      amountMinor: number;
      currency: string;
      purpose: string;
      evidenceUri: string;
      executeFrom: string;
      executeUntil: string;
      idempotencyKey: string;
    },
  ) {
    const request = validateDisbursementRequest({
      channel: 'internal',
      beneficiaryKind: input.beneficiaryKind,
      beneficiaryMemberId: input.beneficiaryMemberId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      purpose: input.purpose,
      evidenceUri: input.evidenceUri,
    });

    assertFundsAvailable({
      availableMinor: await this.getAvailableMinor(context),
      amountMinor: request.amountMinor,
    });

    const { data, error } = await supabase.rpc('request_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_budget_id: input.budgetId,
      p_proposal_id: input.proposalId,
      p_beneficiary_kind: request.beneficiaryKind,
      p_beneficiary_member_id: request.beneficiaryMemberId,
      p_beneficiary_group_id: input.beneficiaryGroupId ?? null,
      p_beneficiary_project_id: input.beneficiaryProjectId ?? null,
      p_amount_minor: request.amountMinor,
      p_currency: request.currency,
      p_purpose: request.purpose,
      p_evidence_uri: request.evidenceUri,
      p_execute_from: input.executeFrom,
      p_execute_until: input.executeUntil,
      p_requested_by: context.actorId,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: correlationId(
        context, `treasury-request:${input.budgetId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { disbursementId: data };
  }

  /**
   * Countersigns a request and reserves the funds in the same transaction. The
   * separation check is repeated here so an API caller is refused before the
   * engine is reached; the engine enforces it again under lock.
   */
  async approveDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { idempotencyKey: string },
  ) {
    const existing = await this.getDisbursement(context, disbursementId);
    if (existing) {
      assertSeparationOfDuties({
        requestedByUserId: existing.requestedBy,
        checkerUserId: context.actorId,
        beneficiaryUserId: existing.beneficiaryUserId,
      });
    }

    const { data, error } = await supabase.rpc('approve_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_final_checker_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-approve:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { reservationId: data };
  }

  /**
   * Posts the payment. Execution revalidates what approval assumed rather than
   * trusting it, because the constitution may have changed and the budget may
   * have been closed in between (clause 5).
   */
  async executeDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('execute_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-execute:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { journalEntryId: data };
  }

  /**
   * Releases the reservation behind an unexecuted disbursement, returning the
   * funds to available. A reservation is consumed or released exactly once, so a
   * repeat release reports false rather than double-crediting the treasury
   * (clause 7).
   */
  async releaseReservation(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { reasonCode: string; idempotencyKey: string },
  ) {
    validateReleaseReasonCode(input.reasonCode);
    const { data, error } = await supabase.rpc('release_group_treasury_reservation', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_reason_code: input.reasonCode,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-release:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { released: data === true };
  }

  /**
   * Reverses a posted payment with an opposing journal. The original entry is
   * never deleted, so the register keeps both the payment and its correction
   * (clause 7).
   */
  async reverseDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { reasonCode: string; idempotencyKey: string },
  ) {
    validateReleaseReasonCode(input.reasonCode);
    const { data, error } = await supabase.rpc('reverse_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_reason_code: input.reasonCode,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-reverse:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { reversalJournalEntryId: data };
  }

  async listDisbursements(
    context: GroupTreasuryContext,
    filters: { state?: string; budgetId?: string } = {},
  ) {
    let query = supabase
      .from('group_treasury_disbursements')
      .select(DISBURSEMENT_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (filters.state) query = query.eq('state', filters.state);
    if (filters.budgetId) query = query.eq('budget_id', filters.budgetId);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(publicDisbursement);
  }

  async getDisbursement(context: GroupTreasuryContext, disbursementId: string) {
    const { data, error } = await supabase
      .from('group_treasury_disbursements')
      .select(DISBURSEMENT_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('id', disbursementId)
      .maybeSingle();
    if (error) throw error;
    return publicDisbursement(data);
  }

  async listReservations(context: GroupTreasuryContext, state?: string) {
    let query = supabase
      .from('group_treasury_reservations')
      .select(RESERVATION_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (state) query = query.eq('state', state);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(publicReservation);
  }
}

export default new GroupTreasuryDisbursementService();
