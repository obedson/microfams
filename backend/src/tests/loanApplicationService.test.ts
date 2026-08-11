import {
  CreateLoanApplicationCommand,
  LoanApplicationGateway,
  LoanApplicationService,
} from '../domains/financial/loanApplicationService.js';

const organizationId = '00000000-0000-4000-8000-000000000201';
const actorId = '00000000-0000-4000-8000-000000000202';
const productId = '00000000-0000-4000-8000-000000000203';
const applicationId = '00000000-0000-4000-8000-000000000204';

const gateway = (): jest.Mocked<LoanApplicationGateway> => ({
  createApplication: jest.fn(),
  submitApplication: jest.fn(),
  requestAdverseReview: jest.fn(),
  decideAdverseReview: jest.fn(),
  withdrawApplication: jest.fn(),
  listApplications: jest.fn(),
});

const command: CreateLoanApplicationCommand = {
  organizationId,
  actorId,
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
  idempotencyKey: 'loan-application-command-1',
};

describe('LoanApplicationService', () => {
  it('passes a complete self-application snapshot to storage', async () => {
    const storage = gateway();
    storage.createApplication.mockResolvedValue({ application: { id: applicationId, state: 'draft' } });
    const service = new LoanApplicationService(storage);

    await expect(service.createApplication(command)).resolves.toMatchObject({ application: { state: 'draft' } });
    expect(storage.createApplication).toHaveBeenCalledWith(command);
  });

  it('rejects floating-point money and unsafe individual impersonation', () => {
    const storage = gateway();
    const service = new LoanApplicationService(storage);
    expect(() => service.createApplication({ ...command, requestedPrincipalMinor: 10.5 })).toThrow('minor units');
    expect(() => service.createApplication({ ...command, borrowerId: organizationId })).toThrow('only for themselves');
    expect(storage.createApplication).not.toHaveBeenCalled();
  });

  it('requires a tenant resource for group and organization borrowers', () => {
    const service = new LoanApplicationService(gateway());
    expect(() => service.createApplication({ ...command, borrowerType: 'group' })).toThrow('borrower ID');
    expect(() => service.createApplication({ ...command, borrowerType: 'organization' })).toThrow('borrower ID');
  });

  it('accepts only bounded reference identifiers rather than raw evidence payloads', () => {
    const service = new LoanApplicationService(gateway());
    expect(() => service.createApplication({ ...command, incomeEvidenceReferences: ['raw evidence with spaces'] })).toThrow('references');
    expect(() => service.createApplication({
      ...command, incomeEvidenceReferences: Array.from({ length: 21 }, (_, index) => `evidence:${index}`),
    })).toThrow('references');
  });

  it('keeps submission as a separate idempotent command', async () => {
    const storage = gateway();
    storage.submitApplication.mockResolvedValue({ application: { state: 'credit_review' } });
    const service = new LoanApplicationService(storage);
    const lifecycle = { organizationId, actorId, applicationId, idempotencyKey: 'loan-application-submit-1' };

    await expect(service.submitApplication(lifecycle)).resolves.toMatchObject({ application: { state: 'credit_review' } });
    expect(storage.submitApplication).toHaveBeenCalledWith(lifecycle);
  });

  it('requires understandable human-review reasons and controlled decisions', async () => {
    const storage = gateway();
    storage.requestAdverseReview.mockResolvedValue({ state: 'requested' });
    storage.decideAdverseReview.mockResolvedValue({ adverse_review: { state: 'reopened' } });
    const service = new LoanApplicationService(storage);
    const base = { organizationId, actorId, applicationId, idempotencyKey: 'loan-adverse-review-1' };

    expect(() => service.requestAdverseReview({ ...base, reason: 'too short', evidenceReferences: [] })).toThrow('12 to 1000');
    await service.requestAdverseReview({
      ...base, reason: 'My verified income evidence was not considered.', evidenceReferences: ['income:test:amended'],
    });
    await service.decideAdverseReview({
      ...base, idempotencyKey: 'loan-adverse-decision-1', decision: 'reopen',
      reason: 'The amended evidence resolves the automated reason code.',
    });
    expect(storage.requestAdverseReview).toHaveBeenCalledTimes(1);
    expect(storage.decideAdverseReview).toHaveBeenCalledTimes(1);
  });

  it('validates controlled withdrawal reason codes', async () => {
    const storage = gateway();
    storage.withdrawApplication.mockResolvedValue({ state: 'withdrawn' });
    const service = new LoanApplicationService(storage);
    const base = { organizationId, actorId, applicationId, idempotencyKey: 'loan-withdraw-command-1' };

    expect(() => service.withdrawApplication({ ...base, reasonCode: 'changed mind' })).toThrow('reason code');
    await expect(service.withdrawApplication({ ...base, reasonCode: 'APPLICANT_CHANGED_PLANS' })).resolves.toMatchObject({ state: 'withdrawn' });
  });
});
