import {
  CreateLoanProductCommand,
  LoanProductGateway,
  LoanProductService,
} from '../domains/financial/loanProductService.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const productId = '00000000-0000-4000-8000-000000000103';

const gateway = (): jest.Mocked<LoanProductGateway> => ({
  createProduct: jest.fn(),
  reviseProduct: jest.fn(),
  submitProduct: jest.fn(),
  approveProduct: jest.fn(),
  listActiveProducts: jest.fn(),
  listGovernedProducts: jest.fn(),
});

const productCommand: CreateLoanProductCommand = {
  organizationId,
  actorId,
  code: 'CRD.INPUTS',
  name: 'Seasonal input credit',
  currency: 'NGN',
  lenderType: 'licensed_provider',
  lenderName: 'Test Lending Partner',
  providerCode: 'PROVIDER.TEST',
  eligibleBorrowerTypes: ['individual', 'group'],
  purposes: ['farm_inputs', 'working_capital'],
  minimumPrincipalMinor: 100000,
  maximumPrincipalMinor: 50000000,
  minimumTenorDays: 30,
  maximumTenorDays: 365,
  repaymentFrequency: 'monthly',
  interestMethod: 'reducing_balance',
  nominalAnnualRateBasisPoints: 1800,
  aprBasisPoints: 1950,
  effectiveAnnualCostBasisPoints: 2100,
  fees: [{ code: 'origination_fee', label: 'Origination fee', calculation: 'percentage', rateBasisPoints: 100, timing: 'disbursement', capitalized: false }],
  gracePeriodDays: 7,
  collateralRules: { required: false, acceptedTypes: [] },
  guaranteeRules: { required: true, minimumGuarantors: 1 },
  affordabilityRules: { maximumDebtServiceRatioBasisPoints: 4000, minimumVerifiedIncomeMonths: 3 },
  delinquencyStages: [
    { code: 'late', label: 'Late', startsAfterDays: 1, classification: 'late' },
    { code: 'delinquent', label: 'Delinquent', startsAfterDays: 30, classification: 'delinquent' },
    { code: 'defaulted', label: 'Defaulted', startsAfterDays: 90, classification: 'defaulted' },
  ],
  restructuringPolicy: { allowed: true, maximumRestructures: 1, independentApprovalRequired: true },
  writeOffPolicy: { eligibleAfterDaysPastDue: 180, independentApprovalRequired: true, collectionContinues: true },
  repaymentAllocationOrder: ['statutory_charges', 'collection_costs', 'penalties', 'accrued_interest', 'principal'],
  penaltyCompoundingAllowed: false,
  disclosureVersion: '2026.1',
  disclosureContentHash: 'a'.repeat(64),
  idempotencyKey: 'loan-product-command-1',
};

describe('LoanProductService', () => {
  it('passes the complete integer-minor-unit product snapshot to storage', async () => {
    const storage = gateway();
    storage.createProduct.mockResolvedValue({ product: { id: productId }, version: { version: 1 } });
    const service = new LoanProductService(storage);

    await expect(service.createProduct(productCommand)).resolves.toMatchObject({ version: { version: 1 } });
    expect(storage.createProduct).toHaveBeenCalledWith(productCommand);
  });

  it('rejects floating-point principal and understated total cost', () => {
    const storage = gateway();
    const service = new LoanProductService(storage);

    expect(() => service.createProduct({ ...productCommand, minimumPrincipalMinor: 100.5 })).toThrow('minor units');
    expect(() => service.createProduct({ ...productCommand, aprBasisPoints: 1700 })).toThrow('must not understate');
    expect(storage.createProduct).not.toHaveBeenCalled();
  });

  it('requires complete and unique repayment allocation components', () => {
    const service = new LoanProductService(gateway());
    expect(() => service.createProduct({
      ...productCommand,
      repaymentAllocationOrder: ['statutory_charges', 'collection_costs', 'penalties', 'principal', 'principal'],
    })).toThrow('repayment allocation order');
  });

  it('requires ordered delinquency stages', () => {
    const service = new LoanProductService(gateway());
    expect(() => service.createProduct({
      ...productCommand,
      delinquencyStages: [
        { code: 'defaulted', label: 'Defaulted', startsAfterDays: 90, classification: 'defaulted' },
        { code: 'late', label: 'Late', startsAfterDays: 1, classification: 'late' },
      ],
    })).toThrow('strictly increasing');
  });

  it('requires external provider identity without accepting credentials', () => {
    const service = new LoanProductService(gateway());
    expect(() => service.createProduct({ ...productCommand, providerCode: undefined })).toThrow('provider code');
    expect(() => service.createProduct({ ...productCommand, providerCode: 'secret token value' })).toThrow('Provider code');
  });

  it('allows penalty compounding only with explicit legal evidence', () => {
    const service = new LoanProductService(gateway());
    expect(() => service.createProduct({ ...productCommand, penaltyCompoundingAllowed: true })).toThrow('approved legal basis');
    expect(() => service.createProduct({
      ...productCommand,
      penaltyCompoundingAllowed: true,
      penaltyCompoundingLegalBasis: 'Approved jurisdictional legal opinion FIN-2026-04.',
    })).not.toThrow();
  });

  it('creates immutable revisions against an expected active version', async () => {
    const storage = gateway();
    storage.reviseProduct.mockResolvedValue({ version: { version: 2, state: 'draft' } });
    const service = new LoanProductService(storage);
    const { code: _code, name: _name, currency: _currency, ...facts } = productCommand;
    const command = { ...facts, productId, expectedCurrentVersion: 1, disclosureVersion: '2026.2', idempotencyKey: 'loan-revision-command-1' };

    await expect(service.reviseProduct(command)).resolves.toMatchObject({ version: { version: 2 } });
    expect(storage.reviseProduct).toHaveBeenCalledWith(command);
  });

  it('keeps submission and independent approval as separate commands', async () => {
    const storage = gateway();
    storage.submitProduct.mockResolvedValue({ state: 'pending_approval' });
    storage.approveProduct.mockResolvedValue({ state: 'active' });
    const service = new LoanProductService(storage);
    const command = { organizationId, actorId, productId, version: 1, idempotencyKey: 'loan-lifecycle-command-1' };

    await service.submitProduct(command);
    await service.approveProduct({ ...command, idempotencyKey: 'loan-lifecycle-command-2' });
    expect(storage.submitProduct).toHaveBeenCalledTimes(1);
    expect(storage.approveProduct).toHaveBeenCalledTimes(1);
  });
});
