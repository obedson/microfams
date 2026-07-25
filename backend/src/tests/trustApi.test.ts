import { jest } from '@jest/globals';
import { trustController } from '../controllers/trustController.js';
import { trustReviewService } from '../domains/trust/trustReviewService.js';
import { TrustDomainError } from '../domains/trust/trustRules.js';

jest.mock('../domains/trust/trustReviewService.js', () => ({
  trustReviewService: {
    getSubjectStatus: jest.fn(),
    listDecisions: jest.fn(),
    fileAppeal: jest.fn(),
    suspendMembership: jest.fn(),
    resumeMembership: jest.fn(),
    listReviewQueue: jest.fn(),
    openReview: jest.fn(),
    assignReview: jest.fn(),
    declareReviewerConflict: jest.fn(),
    decideReview: jest.fn(),
    listAppealQueue: jest.fn(),
    decideAppeal: jest.fn(),
    createRetentionDryRun: jest.fn(),
    suspendOrganization: jest.fn(),
    resumeOrganization: jest.fn(),
  },
}));

const USER_ID = '00000000-0000-4000-8000-000000000101';
const ORGANIZATION_ID = '00000000-0000-4000-8000-000000000102';
const MEMBERSHIP_ID = '00000000-0000-4000-8000-000000000103';
const CASE_ID = '00000000-0000-4000-8000-000000000104';
const APPEAL_ID = '00000000-0000-4000-8000-000000000105';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const tenant = {
  id: ORGANIZATION_ID,
  name: 'Ada Farms',
  slug: 'ada-farms',
  type: 'farm_business',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: MEMBERSHIP_ID,
  userId: USER_ID,
  role: 'owner',
  permissions: [],
};

describe('trust API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('only reads trust status for the authenticated user', async () => {
    (trustReviewService.getSubjectStatus as jest.Mock).mockResolvedValue({ state: 'clear' } as never);
    const res = response();

    await trustController.getSelfStatus({
      user: { id: USER_ID },
      query: { userId: '00000000-0000-4000-8000-000000000999' },
    } as any, res);

    expect(trustReviewService.getSubjectStatus).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: USER_ID }),
      'user',
      USER_ID,
    );
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: { state: 'clear' },
    });
  });

  it('files an appeal without accepting actor or tenant scope from the body', async () => {
    (trustReviewService.fileAppeal as jest.Mock).mockResolvedValue({ id: APPEAL_ID } as never);
    const res = response();

    await trustController.fileSelfAppeal({
      user: { id: USER_ID },
      headers: { 'idempotency-key': 'appeal-command-101' },
      body: {
        caseId: CASE_ID,
        grounds: 'The decision omitted verified evidence I previously submitted.',
        actorId: '00000000-0000-4000-8000-000000000999',
        organizationId: '00000000-0000-4000-8000-000000000999',
      },
    } as any, res);

    expect(trustReviewService.fileAppeal).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: USER_ID }),
      {
        caseId: CASE_ID,
        grounds: 'The decision omitted verified evidence I previously submitted.',
        idempotencyKey: 'appeal-command-101',
      },
    );
    expect(res.status).toHaveBeenCalledWith(202);
  });

  it('requires an idempotency key for trust commands', async () => {
    const res = response();
    await trustController.fileSelfAppeal({
      user: { id: USER_ID },
      headers: {},
      body: {
        caseId: CASE_ID,
        grounds: 'The decision omitted verified evidence I previously submitted.',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'IDEMPOTENCY_KEY_REQUIRED',
    });
    expect(trustReviewService.fileAppeal).not.toHaveBeenCalled();
  });

  it('binds a membership suspension to the resolved tenant', async () => {
    (trustReviewService.suspendMembership as jest.Mock).mockResolvedValue({ status: 'active' } as never);
    const res = response();

    await trustController.suspendMembership({
      user: { id: USER_ID },
      tenant,
      params: { membershipId: MEMBERSHIP_ID },
      headers: { 'idempotency-key': 'membership-suspend-101' },
      body: { caseId: CASE_ID, reasonCode: 'policy_breach' },
    } as any, res);

    expect(trustReviewService.suspendMembership).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: USER_ID,
        organizationId: ORGANIZATION_ID,
      }),
      {
        membershipId: MEMBERSHIP_ID,
        caseId: CASE_ID,
        reasonCode: 'POLICY_BREACH',
        idempotencyKey: 'membership-suspend-101',
      },
    );
  });

  it('returns a generic response for cross-tenant resource failures', async () => {
    (trustReviewService.suspendMembership as jest.Mock).mockRejectedValue(
      new TrustDomainError('TRUST_SCOPE_VIOLATION', 403, 'organization mismatch') as never,
    );
    const res = response();

    await trustController.suspendMembership({
      user: { id: USER_ID },
      tenant,
      params: { membershipId: MEMBERSHIP_ID },
      headers: { 'idempotency-key': 'membership-suspend-102' },
      body: { caseId: CASE_ID, reasonCode: 'POLICY_BREACH' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'TRUST_RESOURCE_NOT_FOUND',
      message: 'The requested trust resource was not found',
    });
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0]))
      .not.toContain('organization mismatch');
  });

  it('marks platform queue reads as platform-administrator operations', async () => {
    (trustReviewService.listReviewQueue as jest.Mock).mockResolvedValue([] as never);
    const res = response();

    await trustController.listReviews({
      user: { id: USER_ID },
      query: { state: 'OPEN', limit: '25' },
    } as any, res);

    expect(trustReviewService.listReviewQueue).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: USER_ID,
        platformAdministrator: true,
      }),
      { state: 'open', limit: 25 },
    );
  });

  it('does not expose unexpected persistence errors', async () => {
    (trustReviewService.decideAppeal as jest.Mock).mockRejectedValue(
      new Error('database connection details') as never,
    );
    const res = response();

    await trustController.decideAppeal({
      user: { id: USER_ID },
      params: { appealId: APPEAL_ID },
      headers: { 'idempotency-key': 'appeal-decision-101' },
      body: {
        outcome: 'overturned',
        reasonCode: 'new_evidence',
        rationale: 'The new evidence conclusively resolves the original concern.',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'TRUST_SERVICE_UNAVAILABLE',
    });
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0]))
      .not.toContain('database');
  });

  it('creates retention plans only through the platform-admin dry-run command', async () => {
    (trustReviewService.createRetentionDryRun as jest.Mock).mockResolvedValue({ mode: 'dry_run' } as never);
    const res = response();

    await trustController.createRetentionDryRun({
      user: { id: USER_ID },
      headers: { 'idempotency-key': 'retention-dry-run-101' },
      body: { organizationId: ORGANIZATION_ID, policyId: CASE_ID },
    } as any, res);

    expect(trustReviewService.createRetentionDryRun).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: USER_ID, platformAdministrator: true }),
      { organizationId: ORGANIZATION_ID, policyId: CASE_ID, idempotencyKey: 'retention-dry-run-101' },
    );
    expect(res.status).toHaveBeenCalledWith(202);
  });

});
