import { LoanOfferController } from '../controllers/loanOfferController.js';
import { LoanOfferService } from '../domains/financial/loanOfferService.js';

const organizationId = '00000000-0000-4000-8000-000000000301';
const actorId = '00000000-0000-4000-8000-000000000302';
const applicationId = '00000000-0000-4000-8000-000000000303';
const offerId = '00000000-0000-4000-8000-000000000304';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
  issue: jest.fn(), decline: jest.fn(), accept: jest.fn(), expire: jest.fn(),
}) as unknown as jest.Mocked<LoanOfferService>;

const issueBody = {
  principalMinor: 900000,
  tenorDays: 180,
  totalInterestMinor: 180000,
  totalFeesMinor: 20000,
  totalRepayableMinor: 1100000,
  conditionCodes: ['SIGNED_MANDATE_REQUIRED'],
  disclosureVersion: 'CRD03.2026.1',
  disclosureContentHash: 'a'.repeat(64),
  expiresAt: '2026-08-20T10:00:00.000Z',
  reasonCodes: ['MANUAL_REVIEW_APPROVED'],
  reviewReason: 'Verified affordability and identity evidence support this offer.',
  idempotencyKey: 'loan-offer-issue-api-command-1',
};

describe('loan offer API contract', () => {
  it('binds offer issuance to authenticated tenant, reviewer, and route application', async () => {
    const domain = service();
    domain.issue.mockResolvedValue({ offer: { id: offerId } } as never);
    const res = response();
    await new LoanOfferController(domain).issue({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId }, body: issueBody,
    } as any, res);
    expect(domain.issue).toHaveBeenCalledWith({ ...issueBody, organizationId, actorId, applicationId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects major-unit aliases and inconsistent missing aggregates', async () => {
    const domain = service();
    const res = response();
    await new LoanOfferController(domain).issue({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: { ...issueBody, principalMinor: undefined, principal: 9000 },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.issue).not.toHaveBeenCalled();
  });

  it('binds exact offer acceptance to the applicant route context', async () => {
    const domain = service();
    domain.accept.mockResolvedValue({ offer: { state: 'accepted' } } as never);
    const res = response();
    const body = {
      expectedOfferHash: 'b'.repeat(64), acceptanceVersion: 'CRD-03.ACCEPTANCE.1',
      acceptanceContentHash: 'c'.repeat(64), idempotencyKey: 'loan-offer-accept-api-command-1',
    };
    await new LoanOfferController(domain).accept({
      tenant: { id: organizationId }, user: { id: actorId },
      params: { applicationId, offerId }, body,
    } as any, res);
    expect(domain.accept).toHaveBeenCalledWith({ ...body, organizationId, actorId, applicationId, offerId });
  });

  it('does not leak storage details when a credit decline fails', async () => {
    const domain = service();
    domain.decline.mockRejectedValue(new Error('sensitive underwriting row detail') as never);
    const res = response();
    await new LoanOfferController(domain).decline({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: {
        reasonCodes: ['UNVERIFIED_REPAYMENT_CAPACITY'],
        reviewReason: 'The submitted evidence does not establish repayment capacity.',
        idempotencyKey: 'loan-credit-decline-api-command-1',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'LOAN_OFFER_COMMAND_REJECTED', message: expect.not.stringContaining('sensitive'),
    }));
  });

  it('binds expiry servicing to both application and offer route identifiers', async () => {
    const domain = service();
    domain.expire.mockResolvedValue({ offer: { state: 'expired' } } as never);
    const res = response();
    await new LoanOfferController(domain).expire({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId, offerId },
      body: { reasonCode: 'ACCEPTANCE_WINDOW_ELAPSED', idempotencyKey: 'loan-offer-expire-api-command-1' },
    } as any, res);
    expect(domain.expire).toHaveBeenCalledWith(expect.objectContaining({
      organizationId, actorId, applicationId, offerId,
    }));
  });
});
