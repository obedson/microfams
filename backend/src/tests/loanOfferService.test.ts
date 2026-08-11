import {
  IssueLoanOfferCommand,
  LoanOfferGateway,
  LoanOfferService,
} from '../domains/financial/loanOfferService.js';

const organizationId = '00000000-0000-4000-8000-000000000301';
const actorId = '00000000-0000-4000-8000-000000000302';
const applicationId = '00000000-0000-4000-8000-000000000303';
const offerId = '00000000-0000-4000-8000-000000000304';

const gateway = (): jest.Mocked<LoanOfferGateway> => ({
  issue: jest.fn(), decline: jest.fn(), accept: jest.fn(), expire: jest.fn(),
});
const command: IssueLoanOfferCommand = {
  organizationId,
  actorId,
  applicationId,
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
  idempotencyKey: 'loan-offer-issue-command-1',
};

describe('LoanOfferService', () => {
  it('passes complete integer-minor-unit offer facts to storage', async () => {
    const storage = gateway();
    storage.issue.mockResolvedValue({ offer: { id: offerId, state: 'offered' } });
    await expect(new LoanOfferService(storage).issue(command)).resolves.toMatchObject({
      offer: { state: 'offered' },
    });
    expect(storage.issue).toHaveBeenCalledWith(command);
  });

  it('rejects inconsistent aggregates and floating-point money', () => {
    const storage = gateway();
    const service = new LoanOfferService(storage);
    expect(() => service.issue({ ...command, totalRepayableMinor: 1099999 })).toThrow('must equal');
    expect(() => service.issue({ ...command, totalInterestMinor: 100.5 })).toThrow('safe integer');
    expect(storage.issue).not.toHaveBeenCalled();
  });

  it('requires controlled unique reason and condition codes', () => {
    const service = new LoanOfferService(gateway());
    expect(() => service.issue({ ...command, reasonCodes: [] })).toThrow('Decision codes');
    expect(() => service.issue({ ...command, conditionCodes: ['bad condition'] })).toThrow('Condition codes');
    expect(() => service.issue({
      ...command, reasonCodes: ['MANUAL_REVIEW_APPROVED', 'MANUAL_REVIEW_APPROVED'],
    })).toThrow('Decision codes');
  });

  it('validates decline evidence before executing the gateway', async () => {
    const storage = gateway();
    storage.decline.mockResolvedValue({ application: { state: 'declined' } });
    const service = new LoanOfferService(storage);
    const decline = {
      organizationId, actorId, applicationId, reasonCodes: ['UNVERIFIED_REPAYMENT_CAPACITY'],
      reviewReason: 'The submitted evidence does not establish repayment capacity.',
      idempotencyKey: 'loan-credit-decline-command-1',
    };
    await expect(service.decline(decline)).resolves.toMatchObject({ application: { state: 'declined' } });
    expect(() => service.decline({ ...decline, reviewReason: 'too short' })).toThrow('12 to 1000');
  });

  it('binds acceptance to the exact offer and acceptance evidence', async () => {
    const storage = gateway();
    storage.accept.mockResolvedValue({ offer: { state: 'accepted' } });
    const service = new LoanOfferService(storage);
    const acceptance = {
      organizationId, actorId, applicationId, offerId, expectedOfferHash: 'b'.repeat(64),
      acceptanceVersion: 'CRD-03.ACCEPTANCE.1', acceptanceContentHash: 'c'.repeat(64),
      idempotencyKey: 'loan-offer-accept-command-1',
    };
    await expect(service.accept(acceptance)).resolves.toMatchObject({ offer: { state: 'accepted' } });
    expect(() => service.accept({ ...acceptance, expectedOfferHash: 'wrong' })).toThrow('offer hash');
  });

  it('validates servicing expiry reason codes', async () => {
    const storage = gateway();
    storage.expire.mockResolvedValue({ offer: { state: 'expired' } });
    const service = new LoanOfferService(storage);
    const expiry = {
      organizationId, actorId, applicationId, offerId, reasonCode: 'ACCEPTANCE_WINDOW_ELAPSED',
      idempotencyKey: 'loan-offer-expire-command-1',
    };
    await expect(service.expire(expiry)).resolves.toMatchObject({ offer: { state: 'expired' } });
    expect(() => service.expire({ ...expiry, reasonCode: 'elapsed' })).toThrow('reason code');
  });
});
