import { LoanDisbursementController } from '../controllers/loanDisbursementController.js';
import { LoanDisbursementService } from '../domains/financial/loanDisbursementService.js';

const organizationId = '00000000-0000-4000-8000-000000000511';
const actorId = '00000000-0000-4000-8000-000000000512';
const applicationId = '00000000-0000-4000-8000-000000000513';
const destinationId = '00000000-0000-4000-8000-000000000514';
const correlationId = '00000000-0000-4000-8000-000000000515';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
  initializeConditions: jest.fn(), submitConditionEvidence: jest.fn(), decideCondition: jest.fn(),
  proposeDestination: jest.fn(), decideDestination: jest.fn(), beginDisbursement: jest.fn(),
  syncDisbursement: jest.fn(),
}) as unknown as jest.Mocked<LoanDisbursementService>;

describe('loan disbursement API contract', () => {
  it('uses authenticated tenant and actor context for disbursement initiation', async () => {
    const domain = service();
    domain.beginDisbursement.mockResolvedValue({ payout: { state: 'processing' } } as never);
    const res = response();
    await new LoanDisbursementController(domain).beginDisbursement({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: {
        organizationId: '00000000-0000-4000-8000-000000000599',
        actorId: '00000000-0000-4000-8000-000000000598',
        destinationId, correlationId, idempotencyKey: 'loan-disbursement-api-1',
      },
    } as any, res);
    expect(domain.beginDisbursement).toHaveBeenCalledWith({
      organizationId, actorId, applicationId, destinationId, correlationId,
      idempotencyKey: 'loan-disbursement-api-1',
    });
    expect(res.status).toHaveBeenCalledWith(202);
  });

  it('rejects malformed evidence before invoking the domain', async () => {
    const domain = service();
    const res = response();
    await new LoanDisbursementController(domain).submitConditionEvidence({
      tenant: { id: organizationId }, user: { id: actorId },
      params: { applicationId, conditionId: destinationId },
      body: { evidenceReferences: [], idempotencyKey: 'condition-evidence-api-1' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.submitConditionEvidence).not.toHaveBeenCalled();
  });

  it('never leaks provider or database details from rejected commands', async () => {
    const domain = service();
    domain.decideDestination.mockRejectedValue(
      new Error('raw account 0123456789 and cross-tenant row') as never,
    );
    const res = response();
    await new LoanDisbursementController(domain).decideDestination({
      tenant: { id: organizationId }, user: { id: actorId },
      params: { applicationId, destinationId },
      body: {
        decision: 'verify', reason: 'Independent verification completed.',
        idempotencyKey: 'destination-decision-api-1',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'LOAN_DISBURSEMENT_COMMAND_REJECTED',
      message: expect.not.stringContaining('0123456789'),
    }));
  });

  it('does not accept provider selection from the client', async () => {
    const domain = service();
    domain.proposeDestination.mockResolvedValue({ destination: { state: 'proposed' } } as never);
    const res = response();
    await new LoanDisbursementController(domain).proposeDestination({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId },
      body: {
        accountNumber: '0123456789', bankCode: '999', providerName: 'untrusted',
        providerEnvironment: 'live', idempotencyKey: 'destination-proposal-api-1',
      },
    } as any, res);
    expect(domain.proposeDestination).toHaveBeenCalledWith({
      organizationId, actorId, applicationId, accountNumber: '0123456789', bankCode: '999',
      idempotencyKey: 'destination-proposal-api-1',
    });
  });
});
