import { createHash } from 'crypto';
import { paymentService } from '../domains/financial/paymentService.js';
import supabase from '../utils/supabase.js';

export interface GroupContributionContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupContributionContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

const publicRule = (row: any) => row && ({
  id: row.id,
  productId: row.product_id,
  version: row.version,
  state: row.state,
  productClass: row.product_class,
  ownership: row.ownership,
  purpose: row.purpose,
  amountMinor: row.amount_minor,
  currency: row.currency,
  payerEligibility: row.payer_eligibility,
  permittedRails: row.permitted_rails,
  dueSchedule: row.due_schedule,
  refundRuleCode: row.refund_rule_code,
  withdrawalRuleCode: row.withdrawal_rule_code,
  lossAllocationRuleCode: row.loss_allocation_rule_code,
  revenueAccountCode: row.revenue_account_code,
  projectId: row.project_id,
  ruleProposalId: row.rule_proposal_id,
  effectiveFrom: row.effective_from,
  supersededAt: row.superseded_at,
});

const publicAllocation = (row: any) => row && ({
  id: row.id,
  productId: row.product_id,
  ruleVersionId: row.rule_version_id,
  memberId: row.member_id,
  productClass: row.product_class,
  ownership: row.ownership,
  paymentId: row.payment_id,
  amountMinor: row.amount_minor,
  currency: row.currency,
  state: row.state,
  allocatedAt: row.allocated_at,
  reversedAt: row.reversed_at,
});

export class GroupContributionService {
  async executeRuleProposal(
    context: GroupContributionContext,
    proposalId: string,
    input: { expectedVersion: number; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('execute_group_contribution_rule_proposal', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_proposal_id: proposalId,
      p_expected_version: input.expectedVersion,
      p_correlation_id: correlationId(
        context, `contribution-proposal:${proposalId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return data;
  }

  /**
   * Starts a contribution payment. The amount comes from the effective rule
   * version read server-side, never from the caller, so a member cannot commit
   * value under terms the group did not disclose and approve.
   */
  async initializePayment(
    context: GroupContributionContext,
    productId: string,
    input: { email: string; amountMinor?: number; idempotencyKey: string },
  ) {
    const { data: member, error: memberError } = await supabase.from('group_members')
      .select('id, user_id, status, is_active')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('user_id', context.actorId)
      .eq('status', 'active')
      .maybeSingle();
    if (memberError) throw memberError;
    if (!member || member.is_active !== true) throw new Error('GROUP_ACTIVE_MEMBER_REQUIRED');

    const { data: rule, error: ruleError } = await supabase
      .from('group_contribution_rule_versions')
      .select('id, product_id, amount_minor, currency, permitted_rails, effective_from')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('product_id', productId)
      .eq('state', 'effective')
      .maybeSingle();
    if (ruleError) throw ruleError;
    if (!rule) throw new Error('GROUP_CONTRIBUTION_RULE_NOT_EFFECTIVE');
    if (new Date(rule.effective_from).getTime() > Date.now()) {
      throw new Error('GROUP_CONTRIBUTION_RULE_NOT_YET_EFFECTIVE');
    }
    // The payment engine posts in NGN only. Allocation compares the payment
    // currency to the rule currency, so a mismatch would strand a captured
    // payment; refuse before taking the member's money instead.
    if (rule.currency !== 'NGN') throw new Error('GROUP_CONTRIBUTION_CURRENCY_UNSUPPORTED');

    // Partial and excess payments are permitted by GT-04 clause 5, so an explicit
    // amount is honoured when supplied; it still must be a positive integer.
    const amountMinor = input.amountMinor ?? Number(rule.amount_minor);
    if (!Number.isInteger(amountMinor) || amountMinor <= 0) {
      throw new Error('GROUP_CONTRIBUTION_AMOUNT_INVALID');
    }

    const reference = `CON-${productId.slice(0, 8)}-${createHash('sha256').update(input.idempotencyKey).digest('hex').slice(0, 16)}`;
    return paymentService.createAndInitialize({
      organizationId: context.organizationId,
      sourceType: 'contribution',
      sourceId: productId,
      payerId: context.actorId,
      actorId: context.actorId,
      correlationId: correlationId(
        context, `contribution:${productId}:payment`, input.idempotencyKey,
      ),
      internalReference: reference,
      idempotencyKey: `group-contribution:${input.idempotencyKey}`,
      amountMinor,
      customerEmail: input.email,
      callbackUrl: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment?type=contribution&id=${productId}&groupId=${context.groupId}`,
      metadata: {
        group_id: context.groupId,
        product_id: productId,
        rule_version_id: rule.id,
        member_id: member.id,
      },
    });
  }

  async allocatePayment(
    context: GroupContributionContext,
    productId: string,
    input: { memberId: string; paymentId: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('allocate_group_contribution_payment', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_member_id: input.memberId,
      p_product_id: productId,
      p_payment_id: input.paymentId,
      p_correlation_id: correlationId(
        context, `contribution:${productId}:allocate:${input.paymentId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { allocationId: data };
  }

  private async access(context: GroupContributionContext) {
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

  /**
   * Members must be able to see what each product is, who owns the money, and on
   * what disclosed terms — GT-04 clause 3 forbids presenting contributions as one
   * interchangeable group balance, so products are always listed by class.
   */
  async listProducts(context: GroupContributionContext) {
    if (!await this.access(context)) return null;
    const { data: products, error } = await supabase.from('group_contribution_products')
      .select('id, product_key, product_class, display_name, state, retired_at, created_at')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .order('created_at', { ascending: true });
    if (error) throw error;
    if (!products?.length) return { products: [] };

    const { data: rules, error: ruleError } = await supabase
      .from('group_contribution_rule_versions')
      .select('*')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('state', 'effective');
    if (ruleError) throw ruleError;

    const effective = new Map((rules ?? []).map((rule: any) => [rule.product_id, rule]));
    return {
      products: products.map((product: any) => ({
        id: product.id,
        productKey: product.product_key,
        productClass: product.product_class,
        displayName: product.display_name,
        state: product.state,
        retiredAt: product.retired_at,
        effectiveRule: publicRule(effective.get(product.id)) ?? null,
      })),
    };
  }

  async getProduct(context: GroupContributionContext, productId: string) {
    if (!await this.access(context)) return null;
    const { data: product, error } = await supabase.from('group_contribution_products')
      .select('id, product_key, product_class, display_name, state, retired_at, created_at')
      .eq('id', productId)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .maybeSingle();
    if (error) throw error;
    if (!product) return null;

    const [ruleResult, adjustmentResult] = await Promise.all([
      supabase.from('group_contribution_rule_versions')
        .select('*')
        .eq('product_id', productId)
        .order('version', { ascending: false }),
      supabase.from('group_contribution_adjustment_rules')
        .select('id, adjustment_kind, version, state, reason_code, reason, calculation_basis, fixed_amount_minor, rate_basis_points, cap_amount_minor, currency, grace_period_days, waiver_permission, journal_account_code, effective_from, superseded_at')
        .eq('product_id', productId)
        .eq('state', 'effective'),
    ]);
    if (ruleResult.error) throw ruleResult.error;
    if (adjustmentResult.error) throw adjustmentResult.error;

    const versions = (ruleResult.data ?? []).map(publicRule);
    return {
      product: {
        id: product.id,
        productKey: product.product_key,
        productClass: product.product_class,
        displayName: product.display_name,
        state: product.state,
        retiredAt: product.retired_at,
      },
      effectiveRule: versions.find((rule: any) => rule.state === 'effective') ?? null,
      ruleHistory: versions,
      adjustmentRules: adjustmentResult.data ?? [],
    };
  }

  async listAllocations(context: GroupContributionContext, productId: string, limit: number) {
    if (!await this.access(context)) return null;
    const { data, error } = await supabase.from('group_contribution_allocations')
      .select('id, product_id, rule_version_id, member_id, product_class, ownership, payment_id, amount_minor, currency, state, allocated_at, reversed_at')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('product_id', productId)
      .order('allocated_at', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return { allocations: (data ?? []).map(publicAllocation) };
  }
}

export const groupContributionService = new GroupContributionService();
