import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';

export interface GroupCycleContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupCycleContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

const CYCLE_COLUMNS = 'id, product_id, rule_version_id, period_key, period_start, period_end, timezone, due_date, grace_end_date, currency, state, expected_total_minor, obligation_count, accounting_period_id, opened_at, grace_started_at, closing_started_at, closed_at, cancelled_at, close_reason_code, cancellation_reason_code, exception_report';

const OBLIGATION_COLUMNS = 'id, cycle_id, member_id, user_id, expected_minor, adjusted_minor, state, satisfied_at, waived_at, written_off_at';

const publicCycle = (row: any) => row && ({
  id: row.id,
  productId: row.product_id,
  ruleVersionId: row.rule_version_id,
  periodKey: row.period_key,
  periodStart: row.period_start,
  periodEnd: row.period_end,
  timezone: row.timezone,
  dueDate: row.due_date,
  graceEndDate: row.grace_end_date,
  currency: row.currency,
  state: row.state,
  expectedTotalMinor: row.expected_total_minor,
  obligationCount: row.obligation_count,
  accountingPeriodId: row.accounting_period_id,
  openedAt: row.opened_at,
  graceStartedAt: row.grace_started_at,
  closingStartedAt: row.closing_started_at,
  closedAt: row.closed_at,
  cancelledAt: row.cancelled_at,
  closeReasonCode: row.close_reason_code,
  cancellationReasonCode: row.cancellation_reason_code,
  exceptionReport: row.exception_report,
});

const publicObligation = (row: any) => row && ({
  id: row.id,
  cycleId: row.cycle_id,
  memberId: row.member_id,
  userId: row.user_id,
  // The original billed amount is never rewritten; a change shows up as the
  // adjusted delta beside it (clause 4).
  expectedMinor: row.expected_minor,
  adjustedMinor: row.adjusted_minor,
  owedMinor: Number(row.expected_minor) + Number(row.adjusted_minor),
  state: row.state,
  satisfiedAt: row.satisfied_at,
  waivedAt: row.waived_at,
  writtenOffAt: row.written_off_at,
});

/**
 * GT-05 cycle operations. Every state change goes through a database function so
 * the cycle, its obligations, and the evidence move in one transaction; this
 * layer only resolves the caller's standing and shapes the response.
 */
export class GroupContributionCycleService {
  async openCycle(
    context: GroupCycleContext,
    input: {
      productId: string;
      periodKey: string;
      periodStart: string;
      periodEnd: string;
      dueDate: string;
      timezone: string;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('open_group_contribution_cycle', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_product_id: input.productId,
      p_period_key: input.periodKey,
      p_period_start: input.periodStart,
      p_period_end: input.periodEnd,
      p_due_date: input.dueDate,
      p_timezone: input.timezone,
      p_correlation_id: correlationId(
        context, `cycle-open:${input.productId}:${input.periodKey}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { cycleId: data };
  }

  /**
   * Waives, reduces, corrects, or writes off part of one member's obligation.
   * The engine records the reason and the actor and preserves the original
   * amount, so a reduction always carries its warrant (clause 4).
   */
  async adjustObligation(
    context: GroupCycleContext,
    obligationId: string,
    input: {
      adjustmentKind: string;
      deltaMinor: number;
      reasonCode: string;
      reason: string;
      evidence?: Record<string, unknown>;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('adjust_group_contribution_obligation', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_obligation_id: obligationId,
      p_adjustment_kind: input.adjustmentKind,
      p_delta_minor: input.deltaMinor,
      p_reason_code: input.reasonCode,
      p_reason: input.reason,
      p_evidence: input.evidence ?? {},
      p_correlation_id: correlationId(
        context, `obligation-adjust:${obligationId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { adjustmentId: data };
  }

  async transitionCycle(
    context: GroupCycleContext,
    cycleId: string,
    input: { toState: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('transition_group_contribution_cycle', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_cycle_id: cycleId,
      p_to_state: input.toState,
      p_correlation_id: correlationId(
        context, `cycle-transition:${cycleId}:${input.toState}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { state: data };
  }

  /**
   * Closes a cycle. The engine refuses to close over unresolved exceptions
   * unless they are acknowledged explicitly, so an operator cannot make an
   * arrears problem disappear by closing the period on top of it (clause 6).
   */
  async closeCycle(
    context: GroupCycleContext,
    cycleId: string,
    input: {
      reasonCode: string;
      acknowledgeExceptions: boolean;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('close_group_contribution_cycle', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_cycle_id: cycleId,
      p_close_reason_code: input.reasonCode,
      p_acknowledge_exceptions: input.acknowledgeExceptions,
      p_correlation_id: correlationId(
        context, `cycle-close:${cycleId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { exceptionReport: data };
  }

  async cancelCycle(
    context: GroupCycleContext,
    cycleId: string,
    input: { reasonCode: string; reason: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('cancel_group_contribution_cycle', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_cycle_id: cycleId,
      p_reason_code: input.reasonCode,
      p_reason: input.reason,
      p_correlation_id: correlationId(
        context, `cycle-cancel:${cycleId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { cycleId: data };
  }

  async listCycles(context: GroupCycleContext, productId: string | null, limit: number) {
    if (!await this.access(context)) return null;
    let query = supabase.from('group_contribution_cycles')
      .select(CYCLE_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (productId) query = query.eq('product_id', productId);
    const { data, error } = await query
      .order('period_start', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return { cycles: (data ?? []).map(publicCycle) };
  }

  /**
   * The cycle dashboard. The money figures come from the database read model,
   * which derives them from posted allocations rather than a stored counter, so
   * a reversed allocation stops counting as received (clause 7).
   */
  async getCycle(context: GroupCycleContext, cycleId: string) {
    if (!await this.access(context)) return null;
    const { data: cycle, error } = await supabase.from('group_contribution_cycles')
      .select(CYCLE_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('id', cycleId)
      .maybeSingle();
    if (error) throw error;
    if (!cycle) return null;

    const [obligations, dashboard] = await Promise.all([
      supabase.from('group_contribution_obligations')
        .select(OBLIGATION_COLUMNS)
        .eq('organization_id', context.organizationId)
        .eq('cycle_id', cycleId)
        .order('state', { ascending: true }),
      supabase.rpc('read_group_contribution_cycle_dashboard', {
        p_organization_id: context.organizationId,
        p_group_id: context.groupId,
        p_actor_id: context.actorId,
        p_cycle_id: cycleId,
      }),
    ]);
    if (obligations.error) throw obligations.error;
    if (dashboard.error) throw dashboard.error;

    return {
      cycle: publicCycle(cycle),
      obligations: (obligations.data ?? []).map(publicObligation),
      totals: dashboard.data ?? null,
    };
  }

  private async access(context: GroupCycleContext) {
    const { data: membership } = await supabase.from('group_members')
      .select('id')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('user_id', context.actorId)
      .eq('status', 'active')
      .maybeSingle();
    if (membership) return true;
    const { data } = await supabase.from('organization_memberships')
      .select('role, permissions')
      .eq('organization_id', context.organizationId)
      .eq('user_id', context.actorId)
      .eq('status', 'active')
      .maybeSingle();
    return data?.role === 'owner' || (data?.permissions ?? []).some((permission: string) =>
      ['groups.governance.manage', 'groups.membership.manage', 'groups.audit.read']
        .includes(permission));
  }
}

export const groupContributionCycleService = new GroupContributionCycleService();
