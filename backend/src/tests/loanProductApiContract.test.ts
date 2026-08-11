import { LoanProductController } from '../controllers/loanProductController.js';
import { LoanProductService } from '../domains/financial/loanProductService.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const productId = '00000000-0000-4000-8000-000000000103';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
  createProduct: jest.fn(), reviseProduct: jest.fn(), submitProduct: jest.fn(), approveProduct: jest.fn(),
  listActiveProducts: jest.fn(), listGovernedProducts: jest.fn(),
}) as unknown as jest.Mocked<LoanProductService>;

const body = {
  code: 'CRD.INPUTS', name: 'Seasonal input credit', currency: 'NGN',
  lenderType: 'licensed_provider', lenderName: 'Test Lending Partner', providerCode: 'PROVIDER.TEST',
  eligibleBorrowerTypes: ['individual'], purposes: ['farm_inputs'],
  minimumPrincipalMinor: 100000, maximumPrincipalMinor: 50000000,
  minimumTenorDays: 30, maximumTenorDays: 365, repaymentFrequency: 'monthly',
  interestMethod: 'reducing_balance', nominalAnnualRateBasisPoints: 1800,
  aprBasisPoints: 1950, effectiveAnnualCostBasisPoints: 2100,
  fees: [], gracePeriodDays: 7,
  collateralRules: { required: false }, guaranteeRules: { required: true },
  affordabilityRules: { maximumDebtServiceRatioBasisPoints: 4000 },
  delinquencyStages: [{ code: 'late', label: 'Late', startsAfterDays: 1, classification: 'late' }],
  restructuringPolicy: { allowed: true }, writeOffPolicy: { eligibleAfterDaysPastDue: 180 },
  repaymentAllocationOrder: ['statutory_charges', 'collection_costs', 'penalties', 'accrued_interest', 'principal'],
  penaltyCompoundingAllowed: false, disclosureVersion: '2026.1', disclosureContentHash: 'a'.repeat(64),
  idempotencyKey: 'loan-product-api-command-1',
};

describe('loan product API contract', () => {
  it('binds product creation to the authenticated tenant and actor', async () => {
    const domain = service();
    domain.createProduct.mockResolvedValue({ product: { id: productId } } as never);
    const res = response();
    await new LoanProductController(domain).create({ tenant: { id: organizationId }, user: { id: actorId }, body } as any, res);

    expect(domain.createProduct).toHaveBeenCalledWith({ ...body, organizationId, actorId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects legacy major-unit fields before domain execution', async () => {
    const domain = service();
    const res = response();
    await new LoanProductController(domain).create({
      tenant: { id: organizationId }, user: { id: actorId },
      body: { ...body, minimumPrincipalMinor: undefined, minimumPrincipal: 1000 },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.createProduct).not.toHaveBeenCalled();
  });

  it('binds a revision to the route product and expected current version', async () => {
    const domain = service();
    domain.reviseProduct.mockResolvedValue({ version: { version: 2 } } as never);
    const res = response();
    const { code: _code, name: _name, currency: _currency, ...facts } = body;
    await new LoanProductController(domain).revise({
      tenant: { id: organizationId }, user: { id: actorId }, params: { productId },
      body: { ...facts, expectedCurrentVersion: 1, disclosureVersion: '2026.2', idempotencyKey: 'loan-revision-api-command-1' },
    } as any, res);

    expect(domain.reviseProduct).toHaveBeenCalledWith(expect.objectContaining({ organizationId, actorId, productId, expectedCurrentVersion: 1 }));
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('does not expose storage details when approval is rejected', async () => {
    const domain = service();
    domain.approveProduct.mockRejectedValue(new Error('sensitive database detail') as never);
    const res = response();
    await new LoanProductController(domain).approve({
      tenant: { id: organizationId }, user: { id: actorId }, params: { productId },
      body: { version: 1, idempotencyKey: 'loan-approval-api-command-1' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'LOAN_PRODUCT_COMMAND_REJECTED', message: expect.not.stringContaining('sensitive'),
    }));
  });

  it('uses authenticated tenant context for active product reads', async () => {
    const domain = service();
    domain.listActiveProducts.mockResolvedValue([] as never);
    const res = response();
    await new LoanProductController(domain).listActive({ tenant: { id: organizationId }, user: { id: actorId } } as any, res);
    expect(domain.listActiveProducts).toHaveBeenCalledWith(organizationId, actorId);
  });
});
