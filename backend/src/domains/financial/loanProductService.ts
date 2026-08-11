import { supabase } from '../../utils/supabase.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const CODE_PATTERN = /^[A-Z0-9][A-Z0-9._-]{1,39}$/;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;
const RULE_CODE_PATTERN = /^[a-z][a-z0-9_]{1,39}$/;

export type BorrowerType = 'individual' | 'group' | 'organization';
export type LenderType = 'organization' | 'licensed_provider' | 'partner';
export type RepaymentFrequency = 'weekly' | 'fortnightly' | 'monthly' | 'quarterly' | 'bullet';
export type InterestMethod = 'reducing_balance' | 'flat' | 'simple' | 'zero_interest';
export type RepaymentComponent = 'statutory_charges' | 'collection_costs' | 'penalties' | 'accrued_interest' | 'principal';

export interface LoanFeeRule {
  code: string;
  label: string;
  calculation: 'fixed' | 'percentage';
  amountMinor?: number;
  rateBasisPoints?: number;
  timing: 'application' | 'disbursement' | 'repayment' | 'delinquency';
  capitalized: boolean;
}

export interface DelinquencyStageRule {
  code: string;
  label: string;
  startsAfterDays: number;
  classification: 'late' | 'delinquent' | 'defaulted';
}

export interface LoanProductFacts {
  lenderType: LenderType;
  lenderName: string;
  providerCode?: string;
  eligibleBorrowerTypes: BorrowerType[];
  purposes: string[];
  minimumPrincipalMinor: number;
  maximumPrincipalMinor: number;
  minimumTenorDays: number;
  maximumTenorDays: number;
  repaymentFrequency: RepaymentFrequency;
  interestMethod: InterestMethod;
  nominalAnnualRateBasisPoints: number;
  aprBasisPoints: number;
  effectiveAnnualCostBasisPoints: number;
  fees: LoanFeeRule[];
  gracePeriodDays: number;
  collateralRules: Record<string, unknown>;
  guaranteeRules: Record<string, unknown>;
  affordabilityRules: Record<string, unknown>;
  delinquencyStages: DelinquencyStageRule[];
  restructuringPolicy: Record<string, unknown>;
  writeOffPolicy: Record<string, unknown>;
  repaymentAllocationOrder: RepaymentComponent[];
  penaltyCompoundingAllowed: boolean;
  penaltyCompoundingLegalBasis?: string;
  disclosureVersion: string;
  disclosureContentHash: string;
}

export interface CreateLoanProductCommand extends LoanProductFacts {
  organizationId: string;
  actorId: string;
  code: string;
  name: string;
  currency: string;
  idempotencyKey: string;
}

export interface ReviseLoanProductCommand extends LoanProductFacts {
  organizationId: string;
  actorId: string;
  productId: string;
  expectedCurrentVersion: number;
  idempotencyKey: string;
}

export interface LoanProductLifecycleCommand {
  organizationId: string;
  actorId: string;
  productId: string;
  version: number;
  idempotencyKey: string;
}

export interface LoanProductGateway {
  createProduct(command: CreateLoanProductCommand): Promise<unknown>;
  reviseProduct(command: ReviseLoanProductCommand): Promise<unknown>;
  submitProduct(command: LoanProductLifecycleCommand): Promise<unknown>;
  approveProduct(command: LoanProductLifecycleCommand): Promise<unknown>;
  listActiveProducts(organizationId: string, actorId: string): Promise<unknown[]>;
  listGovernedProducts(organizationId: string, actorId: string): Promise<unknown[]>;
}

export class LoanProductValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoanProductValidationError';
  }
}

const positiveMinor = (value: number, label: string) => {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new LoanProductValidationError(`${label} must be a positive safe integer in minor units.`);
  }
};

const nonNegativeInteger = (value: number, label: string, maximum = Number.MAX_SAFE_INTEGER) => {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    throw new LoanProductValidationError(`${label} must be a non-negative safe integer.`);
  }
};

const objectRule = (value: Record<string, unknown>, label: string) => {
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new LoanProductValidationError(`${label} must be a rule object.`);
  }
};

export class SupabaseLoanProductGateway implements LoanProductGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Loan product storage returned no result.');
    return data;
  }

  private facts(command: LoanProductFacts) {
    return {
      lenderType: command.lenderType,
      lenderName: command.lenderName,
      providerCode: command.providerCode ?? null,
      eligibleBorrowerTypes: command.eligibleBorrowerTypes,
      purposes: command.purposes,
      minimumPrincipalMinor: command.minimumPrincipalMinor,
      maximumPrincipalMinor: command.maximumPrincipalMinor,
      minimumTenorDays: command.minimumTenorDays,
      maximumTenorDays: command.maximumTenorDays,
      repaymentFrequency: command.repaymentFrequency,
      interestMethod: command.interestMethod,
      nominalAnnualRateBasisPoints: command.nominalAnnualRateBasisPoints,
      aprBasisPoints: command.aprBasisPoints,
      effectiveAnnualCostBasisPoints: command.effectiveAnnualCostBasisPoints,
      fees: command.fees,
      gracePeriodDays: command.gracePeriodDays,
      collateralRules: command.collateralRules,
      guaranteeRules: command.guaranteeRules,
      affordabilityRules: command.affordabilityRules,
      delinquencyStages: command.delinquencyStages,
      restructuringPolicy: command.restructuringPolicy,
      writeOffPolicy: command.writeOffPolicy,
      repaymentAllocationOrder: command.repaymentAllocationOrder,
      penaltyCompoundingAllowed: command.penaltyCompoundingAllowed,
      penaltyCompoundingLegalBasis: command.penaltyCompoundingLegalBasis ?? null,
      disclosureVersion: command.disclosureVersion,
      disclosureContentHash: command.disclosureContentHash,
    };
  }

  createProduct(command: CreateLoanProductCommand) {
    return this.rpc('create_loan_product_draft', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_code: command.code,
      p_name: command.name,
      p_currency: command.currency,
      p_facts: this.facts(command),
      p_idempotency_key: command.idempotencyKey,
    });
  }

  reviseProduct(command: ReviseLoanProductCommand) {
    return this.rpc('revise_loan_product', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_product: command.productId,
      p_expected_current_version: command.expectedCurrentVersion,
      p_facts: this.facts(command),
      p_idempotency_key: command.idempotencyKey,
    });
  }

  submitProduct(command: LoanProductLifecycleCommand) {
    return this.rpc('submit_loan_product_version', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_product: command.productId,
      p_version: command.version,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  approveProduct(command: LoanProductLifecycleCommand) {
    return this.rpc('approve_loan_product_version', {
      p_organization: command.organizationId,
      p_actor: command.actorId,
      p_product: command.productId,
      p_version: command.version,
      p_idempotency_key: command.idempotencyKey,
    });
  }

  async listActiveProducts(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_active_loan_products', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Loan product list is invalid.');
    return data;
  }

  async listGovernedProducts(organizationId: string, actorId: string): Promise<unknown[]> {
    const data = await this.rpc('list_governed_loan_products', { p_organization: organizationId, p_actor: actorId });
    if (!Array.isArray(data)) throw new Error('Governed loan product list is invalid.');
    return data;
  }
}

export class LoanProductService {
  constructor(private readonly gateway: LoanProductGateway = new SupabaseLoanProductGateway()) {}

  createProduct(command: CreateLoanProductCommand) {
    this.identity(command.organizationId, command.actorId, command.idempotencyKey);
    if (!CODE_PATTERN.test(command.code)) throw new LoanProductValidationError('Product code is invalid.');
    if (command.name.trim().length < 2 || command.name.trim().length > 160) throw new LoanProductValidationError('Product name is invalid.');
    if (!CURRENCY_PATTERN.test(command.currency)) throw new LoanProductValidationError('Currency must be an uppercase ISO code.');
    this.facts(command);
    return this.gateway.createProduct(command);
  }

  reviseProduct(command: ReviseLoanProductCommand) {
    this.identity(command.organizationId, command.actorId, command.idempotencyKey);
    this.uuid(command.productId, 'Product ID');
    if (!Number.isSafeInteger(command.expectedCurrentVersion) || command.expectedCurrentVersion < 1) {
      throw new LoanProductValidationError('Expected current version must be a positive integer.');
    }
    this.facts(command);
    return this.gateway.reviseProduct(command);
  }

  submitProduct(command: LoanProductLifecycleCommand) {
    this.lifecycle(command);
    return this.gateway.submitProduct(command);
  }

  approveProduct(command: LoanProductLifecycleCommand) {
    this.lifecycle(command);
    return this.gateway.approveProduct(command);
  }

  listActiveProducts(organizationId: string, actorId: string) {
    this.uuid(organizationId, 'Organization ID');
    this.uuid(actorId, 'Actor ID');
    return this.gateway.listActiveProducts(organizationId, actorId);
  }

  listGovernedProducts(organizationId: string, actorId: string) {
    this.uuid(organizationId, 'Organization ID');
    this.uuid(actorId, 'Actor ID');
    return this.gateway.listGovernedProducts(organizationId, actorId);
  }

  private facts(command: LoanProductFacts) {
    if (command.lenderName.trim().length < 2 || command.lenderName.trim().length > 160) {
      throw new LoanProductValidationError('Lender name is invalid.');
    }
    if (command.lenderType !== 'organization' && !command.providerCode?.trim()) {
      throw new LoanProductValidationError('External lender products require a non-secret provider code.');
    }
    if (command.providerCode && !CODE_PATTERN.test(command.providerCode)) {
      throw new LoanProductValidationError('Provider code is invalid.');
    }
    this.uniqueEnum(command.eligibleBorrowerTypes, ['individual', 'group', 'organization'], 'eligible borrower types');
    if (!command.purposes.length || command.purposes.some((purpose) => !RULE_CODE_PATTERN.test(purpose))) {
      throw new LoanProductValidationError('Purposes must contain unique lower-case rule codes.');
    }
    if (new Set(command.purposes).size !== command.purposes.length) throw new LoanProductValidationError('Purposes must be unique.');
    positiveMinor(command.minimumPrincipalMinor, 'Minimum principal');
    positiveMinor(command.maximumPrincipalMinor, 'Maximum principal');
    if (command.maximumPrincipalMinor < command.minimumPrincipalMinor) throw new LoanProductValidationError('Maximum principal cannot be below the minimum.');
    nonNegativeInteger(command.minimumTenorDays, 'Minimum tenor');
    nonNegativeInteger(command.maximumTenorDays, 'Maximum tenor');
    if (command.minimumTenorDays < 1 || command.maximumTenorDays < command.minimumTenorDays) throw new LoanProductValidationError('Tenor bounds are invalid.');
    nonNegativeInteger(command.nominalAnnualRateBasisPoints, 'Nominal annual rate', 100000);
    nonNegativeInteger(command.aprBasisPoints, 'APR', 100000);
    nonNegativeInteger(command.effectiveAnnualCostBasisPoints, 'Effective annual cost', 100000);
    if ((command.interestMethod === 'zero_interest') !== (command.nominalAnnualRateBasisPoints === 0)) {
      throw new LoanProductValidationError('Interest method and nominal rate are inconsistent.');
    }
    if (command.aprBasisPoints < command.nominalAnnualRateBasisPoints
      || command.effectiveAnnualCostBasisPoints < command.aprBasisPoints) {
      throw new LoanProductValidationError('APR and effective annual cost must not understate the configured nominal cost.');
    }
    this.fees(command.fees);
    nonNegativeInteger(command.gracePeriodDays, 'Grace period');
    objectRule(command.collateralRules, 'Collateral rules');
    objectRule(command.guaranteeRules, 'Guarantee rules');
    objectRule(command.affordabilityRules, 'Affordability rules');
    objectRule(command.restructuringPolicy, 'Restructuring policy');
    objectRule(command.writeOffPolicy, 'Write-off policy');
    this.delinquency(command.delinquencyStages);
    this.uniqueEnum(command.repaymentAllocationOrder,
      ['statutory_charges', 'collection_costs', 'penalties', 'accrued_interest', 'principal'], 'repayment allocation order', 5);
    if (command.penaltyCompoundingAllowed) {
      const basis = command.penaltyCompoundingLegalBasis?.trim() ?? '';
      if (basis.length < 12 || basis.length > 500) {
        throw new LoanProductValidationError('Penalty compounding requires an approved legal basis of 12 to 500 characters.');
      }
    } else if (command.penaltyCompoundingLegalBasis) {
      throw new LoanProductValidationError('A penalty-compounding legal basis is only valid when compounding is enabled.');
    }
    if (!command.disclosureVersion.trim() || command.disclosureVersion.trim().length > 80
      || !HASH_PATTERN.test(command.disclosureContentHash)) {
      throw new LoanProductValidationError('A versioned disclosure and SHA-256 content hash are required.');
    }
  }

  private fees(fees: LoanFeeRule[]) {
    if (!Array.isArray(fees)) throw new LoanProductValidationError('Fees must be an array.');
    const codes = new Set<string>();
    for (const fee of fees) {
      if (!RULE_CODE_PATTERN.test(fee.code) || codes.has(fee.code)) throw new LoanProductValidationError('Fee codes must be valid and unique.');
      codes.add(fee.code);
      if (fee.label.trim().length < 2 || fee.label.trim().length > 120) throw new LoanProductValidationError('Fee labels are invalid.');
      if (fee.calculation === 'fixed') {
        positiveMinor(fee.amountMinor as number, `Fee ${fee.code} amount`);
        if (fee.rateBasisPoints !== undefined) throw new LoanProductValidationError('Fixed fees cannot include a percentage rate.');
      } else {
        nonNegativeInteger(fee.rateBasisPoints as number, `Fee ${fee.code} rate`, 100000);
        if ((fee.rateBasisPoints as number) < 1 || fee.amountMinor !== undefined) throw new LoanProductValidationError('Percentage fees require only a positive basis-point rate.');
      }
    }
  }

  private delinquency(stages: DelinquencyStageRule[]) {
    if (!Array.isArray(stages) || !stages.length) throw new LoanProductValidationError('At least one delinquency stage is required.');
    const codes = new Set<string>();
    let prior = -1;
    for (const stage of stages) {
      if (!RULE_CODE_PATTERN.test(stage.code) || codes.has(stage.code)) throw new LoanProductValidationError('Delinquency stage codes must be valid and unique.');
      codes.add(stage.code);
      if (stage.label.trim().length < 2 || stage.label.trim().length > 120) throw new LoanProductValidationError('Delinquency stage labels are invalid.');
      nonNegativeInteger(stage.startsAfterDays, `Delinquency stage ${stage.code}`);
      if (stage.startsAfterDays <= prior) throw new LoanProductValidationError('Delinquency stages must be ordered by strictly increasing days past due.');
      prior = stage.startsAfterDays;
    }
  }

  private uniqueEnum(values: string[], allowed: string[], label: string, exactLength?: number) {
    if (!Array.isArray(values) || !values.length || values.some((value) => !allowed.includes(value))
      || new Set(values).size !== values.length || (exactLength !== undefined && values.length !== exactLength)) {
      throw new LoanProductValidationError(`${label} are invalid or incomplete.`);
    }
  }

  private lifecycle(command: LoanProductLifecycleCommand) {
    this.identity(command.organizationId, command.actorId, command.idempotencyKey);
    this.uuid(command.productId, 'Product ID');
    if (!Number.isSafeInteger(command.version) || command.version < 1) throw new LoanProductValidationError('Version must be a positive integer.');
  }

  private identity(organizationId: string, actorId: string, idempotencyKey: string) {
    this.uuid(organizationId, 'Organization ID');
    this.uuid(actorId, 'Actor ID');
    if (idempotencyKey.length < 8 || idempotencyKey.length > 160) throw new LoanProductValidationError('Idempotency key must contain 8 to 160 characters.');
  }

  private uuid(value: string, label: string) {
    if (!UUID_PATTERN.test(value)) throw new LoanProductValidationError(`${label} must be a valid UUID.`);
  }
}

export const loanProductService = new LoanProductService();
