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

export interface SavingsGateway {
  createProduct(command: CreateSavingsProductCommand): Promise<unknown>;
  submitProduct(command: SavingsLifecycleCommand): Promise<unknown>;
  approveProduct(command: SavingsLifecycleCommand): Promise<unknown>;
  enrol(command: EnrolSavingsCommand): Promise<unknown>;
  listProducts(organizationId: string, actorId: string): Promise<unknown[]>;
  listEnrolments(organizationId: string, actorId: string): Promise<unknown[]>;
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
