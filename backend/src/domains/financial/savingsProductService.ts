import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const CODE_PATTERN = /^[A-Z0-9][A-Z0-9._-]{1,39}$/;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;

export type ContributionFrequency = 'manual' | 'daily' | 'weekly' | 'monthly' | 'quarterly';
export type EarlyWithdrawalRule = 'blocked' | 'allowed' | 'forfeit_returns' | 'fee';
export type SavingsReturnMethod = 'none' | 'simple_interest';
export type DayCountConvention = 'actual_365' | 'actual_360';

export interface CreateSavingsProductCommand {
  organizationId: string;
  actorId: string;
  code: string;
  name: string;
  currency: string;
  minimumContributionMinor: number;
  maximumContributionMinor: number;
  contributionFrequency: ContributionFrequency;
  defaultTargetMinor?: number;
  lockPeriodDays: number;
  gracePeriodDays: number;
  earlyWithdrawalRule: EarlyWithdrawalRule;
  earlyWithdrawalFeeMinor: number;
  returnMethod: SavingsReturnMethod;
  annualRateBasisPoints: number;
  dayCountConvention: DayCountConvention;
  disclosureVersion: string;
  disclosureContentHash: string;
  eligibility: Record<string, unknown>;
  idempotencyKey: string;
}

export interface SavingsLifecycleCommand {
  organizationId: string;
  actorId: string;
  productId: string;
  expectedVersion: number;
  idempotencyKey: string;
}

export interface EnrolSavingsCommand {
  organizationId: string;
  actorId: string;
  productId: string;
  targetMinor?: number;
  disclosureVersion: string;
  disclosureContentHash: string;
  idempotencyKey: string;
}

export interface SavingsContributionCommand {
  organizationId: string;
  actorId: string;
  enrolmentId: string;
  amountMinor: number;
  idempotencyKey: string;
  correlationId: string;
}

export interface CreateSavingsStandingOrderCommand {
  organizationId: string;
  actorId: string;
  enrolmentId: string;
  amountMinor: number;
  firstDueAt: string;
  disclosureVersion: string;
  disclosureContentHash: string;
  idempotencyKey: string;
}

export interface TransitionSavingsStandingOrderCommand {
  organizationId: string;
  actorId: string;
  standingOrderId: string;
  action: 'pause' | 'resume' | 'cancel';
  idempotencyKey: string;
}

export interface CalculateSavingsAccrualCommand {
  organizationId: string;
  actorId: string;
  productVersionId: string;
  periodStart: string;
  periodEnd: string;
  idempotencyKey: string;
  correlationId: string;
}

export interface ReviewSavingsAccrualCommand {
  organizationId: string;
  actorId: string;
  batchId: string;
  action: 'approve' | 'reject';
  reason?: string;
  idempotencyKey: string;
  correlationId: string;
}

export interface SavingsAccrualFormulaInput {
  eligiblePrincipalDaysMinor: bigint;
  annualRateBasisPoints: number;
  dayCountConvention: DayCountConvention;
}

export interface SavingsGateway {
  createProduct(command: CreateSavingsProductCommand): Promise<unknown>;
  submitProduct(command: SavingsLifecycleCommand): Promise<unknown>;
  approveProduct(command: SavingsLifecycleCommand): Promise<unknown>;
  enrol(command: EnrolSavingsCommand): Promise<unknown>;
  listProducts(organizationId: string, actorId: string): Promise<unknown[]>;
  listEnrolments(organizationId: string, actorId: string): Promise<unknown[]>;
  contribute(command: SavingsContributionCommand): Promise<unknown>;
  createStandingOrder(command: CreateSavingsStandingOrderCommand): Promise<unknown>;
  transitionStandingOrder(command: TransitionSavingsStandingOrderCommand): Promise<unknown>;
  listContributions(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]>;
  listStandingOrders(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]>;
  calculateAccrual(command: CalculateSavingsAccrualCommand): Promise<unknown>;
  reviewAccrual(command: ReviewSavingsAccrualCommand): Promise<unknown>;
  listAccrualBatches(organizationId: string, actorId: string): Promise<unknown[]>;
  listAccruals(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]>;
}

export class SavingsValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SavingsValidationError';
  }
}

const assertUuid = (value: string, label: string) => {
  if (!UUID_PATTERN.test(value)) throw new SavingsValidationError(`${label} must be a valid UUID.`);
};

const assertIdempotencyKey = (value: string) => {
  if (value.length < 8 || value.length > 160) {
    throw new SavingsValidationError('Idempotency key must contain 8 to 160 characters.');
  }
};

const assertMinor = (value: number | undefined, label: string, optional = false) => {
  if (optional && value === undefined) return;
  if (!Number.isSafeInteger(value) || (value as number) <= 0) {
    throw new SavingsValidationError(`${label} must be a positive safe integer in minor units.`);
  }
};

const assertIsoDate = (value: string, label: string) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new SavingsValidationError(`${label} must use YYYY-MM-DD.`);
  const date = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    throw new SavingsValidationError(`${label} is not a valid calendar date.`);
  }
};

export const calculateSimpleSavingsAccrualMinor = (input: SavingsAccrualFormulaInput): bigint => {
  if (input.eligiblePrincipalDaysMinor < 0n) {
    throw new SavingsValidationError('Eligible principal-days cannot be negative.');
  }
  if (!Number.isSafeInteger(input.annualRateBasisPoints) || input.annualRateBasisPoints <= 0) {
    throw new SavingsValidationError('Annual rate must be positive basis points.');
  }
  const days = input.dayCountConvention === 'actual_365' ? 365n : 360n;
  const denominator = 10000n * days;
  const numerator = input.eligiblePrincipalDaysMinor * BigInt(input.annualRateBasisPoints);
  return (numerator + denominator / 2n) / denominator;
};

export class SupabaseSavingsGateway implements SavingsGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Savings storage returned no result.');
    return data;
  }

  createProduct(command: CreateSavingsProductCommand) {
    return this.rpc('create_savings_product_draft', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_code: command.code,
      p_name: command.name,
      p_currency: command.currency,
      p_minimum_minor: command.minimumContributionMinor,
      p_maximum_minor: command.maximumContributionMinor,
      p_frequency: command.contributionFrequency,
      p_default_target_minor: command.defaultTargetMinor ?? null,
      p_lock_days: command.lockPeriodDays,
      p_grace_days: command.gracePeriodDays,
      p_early_rule: command.earlyWithdrawalRule,
      p_early_fee_minor: command.earlyWithdrawalFeeMinor,
      p_return_method: command.returnMethod,
      p_annual_rate_bps: command.annualRateBasisPoints,
      p_day_count: command.dayCountConvention,
      p_disclosure_version: command.disclosureVersion,
      p_disclosure_hash: command.disclosureContentHash,
      p_eligibility: command.eligibility,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  submitProduct(command: SavingsLifecycleCommand) {
    return this.rpc('submit_savings_product', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_product: command.productId, p_expected_version: command.expectedVersion,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  approveProduct(command: SavingsLifecycleCommand) {
    return this.rpc('approve_savings_product', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_product: command.productId, p_expected_version: command.expectedVersion,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  enrol(command: EnrolSavingsCommand) {
    return this.rpc('enrol_savings_product', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_product: command.productId, p_target_minor: command.targetMinor ?? null,
      p_disclosure_version: command.disclosureVersion,
      p_disclosure_hash: command.disclosureContentHash,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  async listProducts(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_active_savings_products', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Savings product list is invalid.');
    return data;
  }

  contribute(command: SavingsContributionCommand) {
    return this.rpc('post_savings_contribution', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_enrolment: command.enrolmentId, p_amount_minor: command.amountMinor,
      p_idempotency_key: command.idempotencyKey, p_correlation_id: command.correlationId,
    });
  }

  createStandingOrder(command: CreateSavingsStandingOrderCommand) {
    return this.rpc('create_savings_standing_order', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_enrolment: command.enrolmentId, p_amount_minor: command.amountMinor,
      p_first_due_at: command.firstDueAt, p_disclosure_version: command.disclosureVersion,
      p_disclosure_hash: command.disclosureContentHash, p_idempotency_key: command.idempotencyKey,
    });
  }

  transitionStandingOrder(command: TransitionSavingsStandingOrderCommand) {
    return this.rpc('transition_savings_standing_order', {
      p_organization: command.organizationId, p_actor: command.actorId,
      p_standing_order: command.standingOrderId, p_action: command.action,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  async listContributions(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]> {
    const data = await this.rpc('list_member_savings_contributions', {
      p_organization: organizationId, p_actor: actorId, p_enrolment: enrolmentId,
    });
    if (!Array.isArray(data)) throw new Error('Savings contribution list is invalid.');
    return data;
  }

  async listStandingOrders(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]> {
    const data = await this.rpc('list_member_savings_standing_orders', {
      p_organization: organizationId, p_actor: actorId, p_enrolment: enrolmentId,
    });
    if (!Array.isArray(data)) throw new Error('Savings standing-order list is invalid.');
    return data;
  }

  calculateAccrual(command: CalculateSavingsAccrualCommand) {
    return this.rpc('calculate_savings_accrual_batch', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_product_version: command.productVersionId,
      p_period_start: command.periodStart,
      p_period_end: command.periodEnd,
      p_idempotency_key: command.idempotencyKey,
      p_correlation_id: command.correlationId,
    });
  }

  reviewAccrual(command: ReviewSavingsAccrualCommand) {
    const rpc = command.action === 'approve' ? 'approve_savings_accrual_batch' : 'reject_savings_accrual_batch';
    return this.rpc(rpc, {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_batch: command.batchId,
      ...(command.action === 'reject' ? { p_reason: command.reason } : {}),
      p_idempotency_key: command.idempotencyKey,
      p_correlation_id: command.correlationId,
    });
  }

  async listAccrualBatches(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_savings_accrual_batches', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Savings accrual batch list is invalid.');
    return data;
  }

  async listAccruals(organizationId: string, actorId: string, enrolmentId: string): Promise<unknown[]> {
    const data = await this.rpc('list_member_savings_accruals', {
      p_organization: organizationId, p_actor: actorId, p_enrolment: enrolmentId,
    });
    if (!Array.isArray(data)) throw new Error('Savings accrual list is invalid.');
    return data;
  }

  async listEnrolments(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_member_savings_enrolments', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Savings enrolment list is invalid.');
    return data;
  }
}

export class SavingsProductService {
  constructor(private readonly gateway: SavingsGateway = new SupabaseSavingsGateway()) {}

  createProduct(command: CreateSavingsProductCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    if (!CODE_PATTERN.test(command.code)) throw new SavingsValidationError('Product code is invalid.');
    if (command.name.trim().length < 2 || command.name.length > 160) throw new SavingsValidationError('Product name is invalid.');
    if (!CURRENCY_PATTERN.test(command.currency)) throw new SavingsValidationError('Currency must be an uppercase ISO code.');
    assertMinor(command.minimumContributionMinor, 'Minimum contribution');
    assertMinor(command.maximumContributionMinor, 'Maximum contribution');
    if (command.maximumContributionMinor < command.minimumContributionMinor) {
      throw new SavingsValidationError('Maximum contribution cannot be below the minimum.');
    }
    assertMinor(command.defaultTargetMinor, 'Default target', true);
    if (!Number.isSafeInteger(command.lockPeriodDays) || command.lockPeriodDays < 0
      || !Number.isSafeInteger(command.gracePeriodDays) || command.gracePeriodDays < 0) {
      throw new SavingsValidationError('Lock and grace periods must be non-negative integers.');
    }
    if (!Number.isSafeInteger(command.earlyWithdrawalFeeMinor) || command.earlyWithdrawalFeeMinor < 0
      || (command.earlyWithdrawalRule === 'fee') !== (command.earlyWithdrawalFeeMinor > 0)) {
      throw new SavingsValidationError('Early-withdrawal fee must match the selected rule.');
    }
    if (!Number.isSafeInteger(command.annualRateBasisPoints) || command.annualRateBasisPoints < 0
      || (command.returnMethod === 'none' && command.annualRateBasisPoints !== 0)
      || (command.returnMethod === 'simple_interest' && command.annualRateBasisPoints <= 0)) {
      throw new SavingsValidationError('Return method and annual rate are inconsistent.');
    }
    if (!command.disclosureVersion.trim() || command.disclosureVersion.length > 80
      || !HASH_PATTERN.test(command.disclosureContentHash)) {
      throw new SavingsValidationError('A versioned disclosure and SHA-256 content hash are required.');
    }
    return this.gateway.createProduct(command);
  }

  submitProduct(command: SavingsLifecycleCommand) {
    this.validateLifecycle(command);
    return this.gateway.submitProduct(command);
  }

  approveProduct(command: SavingsLifecycleCommand) {
    this.validateLifecycle(command);
    return this.gateway.approveProduct(command);
  }

  enrol(command: EnrolSavingsCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.productId, 'Product ID');
    assertMinor(command.targetMinor, 'Savings target', true);
    if (!command.disclosureVersion.trim() || command.disclosureVersion.length > 80
      || !HASH_PATTERN.test(command.disclosureContentHash)) {
      throw new SavingsValidationError('The accepted disclosure version and SHA-256 hash are required.');
    }
    return this.gateway.enrol(command);
  }

  contribute(command: SavingsContributionCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.enrolmentId, 'Enrolment ID');
    assertUuid(command.correlationId, 'Correlation ID');
    assertMinor(command.amountMinor, 'Contribution amount');
    return this.gateway.contribute(command);
  }

  createStandingOrder(command: CreateSavingsStandingOrderCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.enrolmentId, 'Enrolment ID');
    assertMinor(command.amountMinor, 'Standing-order amount');
    const firstDueAt = new Date(command.firstDueAt);
    if (Number.isNaN(firstDueAt.getTime()) || firstDueAt.toISOString() !== command.firstDueAt) {
      throw new SavingsValidationError('First due time must be an ISO-8601 UTC timestamp.');
    }
    if (!command.disclosureVersion.trim() || command.disclosureVersion.length > 80
      || !HASH_PATTERN.test(command.disclosureContentHash)) {
      throw new SavingsValidationError('The authorized disclosure version and SHA-256 hash are required.');
    }
    return this.gateway.createStandingOrder(command);
  }

  transitionStandingOrder(command: TransitionSavingsStandingOrderCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.standingOrderId, 'Standing-order ID');
    return this.gateway.transitionStandingOrder(command);
  }

  calculateAccrual(command: CalculateSavingsAccrualCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.productVersionId, 'Product version ID');
    assertUuid(command.correlationId, 'Correlation ID');
    assertIsoDate(command.periodStart, 'Accrual period start');
    assertIsoDate(command.periodEnd, 'Accrual period end');
    if (command.periodEnd <= command.periodStart) {
      throw new SavingsValidationError('Accrual period end must be after its start.');
    }
    return this.gateway.calculateAccrual(command);
  }

  reviewAccrual(command: ReviewSavingsAccrualCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.batchId, 'Accrual batch ID');
    assertUuid(command.correlationId, 'Correlation ID');
    if (command.action === 'reject') {
      const reason = command.reason?.trim() ?? '';
      if (reason.length < 8 || reason.length > 1000) {
        throw new SavingsValidationError('Rejection reason must contain 8 to 1000 characters.');
      }
    } else if (command.reason !== undefined) {
      throw new SavingsValidationError('Approval does not accept a rejection reason.');
    }
    return this.gateway.reviewAccrual(command);
  }

  listContributions(organizationId: string, actorId: string, enrolmentId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    assertUuid(enrolmentId, 'Enrolment ID');
    return this.gateway.listContributions(organizationId, actorId, enrolmentId);
  }

  listStandingOrders(organizationId: string, actorId: string, enrolmentId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    assertUuid(enrolmentId, 'Enrolment ID');
    return this.gateway.listStandingOrders(organizationId, actorId, enrolmentId);
  }

  listAccrualBatches(organizationId: string, actorId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    return this.gateway.listAccrualBatches(organizationId, actorId);
  }

  listAccruals(organizationId: string, actorId: string, enrolmentId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    assertUuid(enrolmentId, 'Enrolment ID');
    return this.gateway.listAccruals(organizationId, actorId, enrolmentId);
  }

  listProducts(organizationId: string, actorId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    return this.gateway.listProducts(organizationId, actorId);
  }

  listEnrolments(organizationId: string, actorId: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    return this.gateway.listEnrolments(organizationId, actorId);
  }

  private validateLifecycle(command: SavingsLifecycleCommand) {
    this.validateIdentity(command.organizationId, command.actorId, command.idempotencyKey);
    assertUuid(command.productId, 'Product ID');
    if (!Number.isSafeInteger(command.expectedVersion) || command.expectedVersion <= 0) {
      throw new SavingsValidationError('Expected product version must be a positive integer.');
    }
  }

  private validateIdentity(organizationId: string, actorId: string, idempotencyKey: string) {
    assertUuid(organizationId, 'Organization ID');
    assertUuid(actorId, 'Actor ID');
    assertIdempotencyKey(idempotencyKey);
  }
}

export const savingsProductService = new SavingsProductService();
