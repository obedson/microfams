import { LoanApplicationController } from '../controllers/loanApplicationController.js';
import { LoanApplicationService } from '../domains/financial/loanApplicationService.js';

const organizationId = '00000000-0000-4000-8000-000000000201';
const actorId = '00000000-0000-4000-8000-000000000202';
const productId = '00000000-0000-4000-8000-000000000203';
const applicationId = '00000000-0000-4000-8000-000000000204';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
  createApplication: jest.fn(), submitApplication: jest.fn(), requestAdverseReview: jest.fn(),
  decideAdverseReview: jest.fn(), withdrawApplication: jest.fn(), listApplications: jest.fn(),
}) as unknown as jest.Mocked<LoanApplicationService>;

const body = {
  productId,
  borrowerType: 'individual',
  purpose: 'farm_inputs',
  requestedPrincipalMinor: 500000,
  requestedTenorDays: 180,
  monthlyNetIncomeMinor: 250000,
  monthlyExistingDebtMinor: 20000,
  verifiedIncomeMonths: 6,
  incomeEvidenceReferences: ['statement:test:2026-07'],
  disclosureVersion: '2026.1',
  disclosureContentHash: 'a'.repeat(64),
  declarationVersion: 'CRD-02.DECLARATION.1',
  declarationContentHash: 'b'.repeat(64),
  idempotencyKey: 'loan-application-api-command-1',
};

describe('loan application API contract', () => {
  it('binds a new application to authenticated tenant and actor context', async () => {
    const domain = service();
    domain.createApplication.mockResolvedValue({ application: { id: applicationId } } as never);
    const res = response();
    await new LoanApplicationController(domain).create({
      tenant: { id: organizationId }, user: { id: actorId }, body,
    } as any, res);

    expect(domain.createApplication).toHaveBeenCalledWith({ ...body, organizationId, actorId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects major-unit aliases before domain execution', async () => {
    const domain = service();
    const res = response();
    await new LoanApplicationController(domain).create({
      tenant: { id: organizationId }, user: { id: actorId },
      body: { ...body, requestedPrincipalMinor: undefined, requestedPrincipal: 5000 },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.createApplication).not.toHaveBeenCalled();
  });

  it('binds submission and review requests to the route application', async () => {
    const domain = service();
    domain.submitApplication.mockResolvedValue({ application: { state: 'declined' } } as never);
    domain.requestAdverseReview.mockResolvedValue({ state: 'requested' } as never);
    const controller = new LoanApplicationController(domain);
    const res = response();
    await controller.submit({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: { idempotencyKey: 'loan-application-submit-api-1' },
    } as any, res);
    await controller.requestAdverseReview({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: {
        reason: 'My updated evidence should be reviewed by a person.', evidenceReferences: ['income:test:amended'],
        idempotencyKey: 'loan-adverse-request-api-1',
      },
    } as any, res);

    expect(domain.submitApplication).toHaveBeenCalledWith(expect.objectContaining({ organizationId, actorId, applicationId }));
    expect(domain.requestAdverseReview).toHaveBeenCalledWith(expect.objectContaining({ organizationId, actorId, applicationId }));
  });

  it('does not expose storage details when a review decision is rejected', async () => {
    const domain = service();
    domain.decideAdverseReview.mockRejectedValue(new Error('sensitive underwriting table detail') as never);
    const res = response();
    await new LoanApplicationController(domain).decideAdverseReview({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: { decision: 'uphold', reason: 'The adverse reasons remain supported by the evidence.', idempotencyKey: 'loan-adverse-decision-api-1' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'LOAN_APPLICATION_COMMAND_REJECTED', message: expect.not.stringContaining('sensitive'),
    }));
  });

  it('uses authenticated tenant context for application history', async () => {
    const domain = service();
    domain.listApplications.mockResolvedValue([] as never);
    const res = response();
    await new LoanApplicationController(domain).list({ tenant: { id: organizationId }, user: { id: actorId } } as any, res);
    expect(domain.listApplications).toHaveBeenCalledWith(organizationId, actorId);
  });
});
