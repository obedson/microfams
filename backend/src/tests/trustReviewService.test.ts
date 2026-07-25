import { TrustReviewService } from '../domains/trust/trustReviewService.js';
import {
  TrustFeatureGate,
  TrustRepository,
} from '../domains/trust/trustTypes.js';

const repository = (): jest.Mocked<TrustRepository> => ({
  getSubjectStatus: jest.fn(),
  listDecisions: jest.fn(),
  listReviewQueue: jest.fn(),
  listAppealQueue: jest.fn(),
  openReview: jest.fn(),
  assignReview: jest.fn(),
  declareReviewerConflict: jest.fn(),
  decideReview: jest.fn(),
  fileAppeal: jest.fn(),
  decideAppeal: jest.fn(),
  suspendOrganization: jest.fn(),
  resumeOrganization: jest.fn(),
  suspendMembership: jest.fn(),
  resumeMembership: jest.fn(),
  createRetentionDryRun: jest.fn(),
  selectRetentionItems: jest.fn(),
});

const gate = (): jest.Mocked<TrustFeatureGate> => ({
  assertNewOperationEnabled: jest.fn().mockResolvedValue(undefined),
});

const context = { actorId: 'actor-1', organizationId: 'org-1', environment: 'test' as const };

describe('trust review service', () => {
  it('normalizes bounded review commands and gates new cases', async () => {
    const repo = repository();
    const flags = gate();
    repo.openReview.mockResolvedValue({ id: 'case-1' });
    const service = new TrustReviewService(repo, flags);

    await service.openReview(context, {
      subjectType: 'membership',
      subjectId: 'membership-1',
      reasonCode: ' policy_breach ',
      idempotencyKey: ' review-001 ',
    });

    expect(flags.assertNewOperationEnabled).toHaveBeenCalledWith({
      ...context,
      capability: 'review',
    });
    expect(repo.openReview).toHaveBeenCalledWith(
      'actor-1',
      expect.objectContaining({
        priority: 'normal',
        reasonCode: 'POLICY_BREACH',
        idempotencyKey: 'review-001',
      }),
      expect.stringMatching(/^[a-f0-9]{64}$/),
    );
  });

  it('keeps remediation available when new operations are disabled', async () => {
    const repo = repository();
    const flags = gate();
    flags.assertNewOperationEnabled.mockRejectedValue(new Error('disabled'));
    repo.resumeOrganization.mockResolvedValue({ resumed: true });
    const service = new TrustReviewService(repo, flags);

    await expect(service.resumeOrganization(context, {
      organizationId: 'org-1',
      reasonCode: 'appeal_approved',
      idempotencyKey: 'resume-001',
    })).resolves.toEqual({ resumed: true });
    expect(flags.assertNewOperationEnabled).not.toHaveBeenCalled();
  });

  it('gates new suspensions while leaving resume operations available', async () => {
    const repo = repository();
    const flags = gate();
    repo.suspendMembership.mockResolvedValue({ suspended: true });
    const service = new TrustReviewService(repo, flags);

    await service.suspendMembership(context, {
      membershipId: 'membership-1',
      caseId: 'case-1',
      reasonCode: 'POLICY_BREACH',
      idempotencyKey: 'suspend-001',
    });

    expect(flags.assertNewOperationEnabled).toHaveBeenCalledWith({
      ...context,
      capability: 'suspension',
    });
  });

  it('gates appeals and retention dry-runs but never exposes a destructive retention operation', async () => {
    const repo = repository();
    const flags = gate();
    repo.fileAppeal.mockResolvedValue({ id: 'appeal-1' });
    repo.createRetentionDryRun.mockResolvedValue({ id: 'run-1', dryRun: true });
    repo.selectRetentionItems.mockResolvedValue({ runId: 'run-1', status: 'completed' });
    const service = new TrustReviewService(repo, flags);

    await service.fileAppeal(context, {
      caseId: 'case-1',
      grounds: 'The submitted evidence was not considered.',
      idempotencyKey: 'appeal-001',
    });
    await service.createRetentionDryRun(context, {
      policyId: 'policy-1',
      organizationId: 'org-1',
      idempotencyKey: 'retain-001',
    });

    expect(flags.assertNewOperationEnabled).toHaveBeenNthCalledWith(
      1, { ...context, capability: 'appeal' },
    );
    expect(flags.assertNewOperationEnabled).toHaveBeenNthCalledWith(
      2, { ...context, capability: 'retention' },
    );
    expect(repo.createRetentionDryRun).toHaveBeenCalled();
    await service.selectRetentionItems(context, {
      runId: 'run-1',
      idempotencyKey: 'retain-select-001',
    });
    expect(flags.assertNewOperationEnabled).toHaveBeenCalledTimes(2);
    expect(repo.selectRetentionItems).toHaveBeenCalledWith(
      'actor-1',
      { runId: 'run-1', idempotencyKey: 'retain-select-001' },
      expect.stringMatching(/^[a-f0-9]{64}$/),
    );
    expect((service as unknown as Record<string, unknown>).executeRetention).toBeUndefined();
  });

  it('rejects oversized rationales and queue requests before persistence', async () => {
    const repo = repository();
    const service = new TrustReviewService(repo, gate());

    await expect(service.decideReview(context, {
      caseId: 'case-1',
      outcome: 'warning',
      reasonCode: 'INSUFFICIENT_EVIDENCE',
      rationale: 'x'.repeat(4001),
      idempotencyKey: 'decision-001',
    })).rejects.toMatchObject({ code: 'INVALID_RATIONALE', status: 400 });
    expect(() => service.listReviewQueue(context, { limit: 201 }))
      .toThrow(expect.objectContaining({ code: 'INVALID_QUEUE_LIMIT' }));
    expect(repo.decideReview).not.toHaveBeenCalled();
  });

  it('does not expose repository error details', async () => {
    const repo = repository();
    repo.suspendMembership.mockRejectedValue(new Error('sensitive database detail'));
    const service = new TrustReviewService(repo, gate());

    await expect(service.suspendMembership(context, {
      membershipId: 'membership-1',
      caseId: 'case-1',
      reasonCode: 'POLICY_BREACH',
      idempotencyKey: 'suspend-001',
    })).rejects.toMatchObject({ code: 'TRUST_COMMAND_FAILED', status: 409 });
  });
});
