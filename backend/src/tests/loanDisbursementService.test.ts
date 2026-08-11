import {
  LoanDisbursementService,
  LoanDisbursementValidationError,
  decryptLoanDisbursementDestination,
  encryptLoanDisbursementDestination,
} from '../domains/financial/loanDisbursementService.js';
import { PayoutAdapter } from '../domains/financial/payoutTypes.js';

const organizationId = '00000000-0000-4000-8000-000000000501';
const actorId = '00000000-0000-4000-8000-000000000502';
const applicationId = '00000000-0000-4000-8000-000000000503';
const destinationId = '00000000-0000-4000-8000-000000000504';
const correlationId = '00000000-0000-4000-8000-000000000505';
const key = Buffer.alloc(32, 7).toString('base64');

const adapter = (): PayoutAdapter => ({
  name: 'deterministic', environment: 'deterministic',
  validateDestination: jest.fn().mockResolvedValue({
    accountName: 'Verified Test Farmer', bankCode: '999',
  }),
  submit: jest.fn(), query: jest.fn(), verifyAndParseWebhook: jest.fn(),
});

const gateway = () => ({
  initializeConditions: jest.fn(), submitConditionEvidence: jest.fn(),
  decideCondition: jest.fn(), proposeDestination: jest.fn(), decideDestination: jest.fn(),
  beginDisbursement: jest.fn(), getDisbursement: jest.fn(),
});

const payouts = () => ({
  assertRoutingEnabled: jest.fn(), submitLoanDisbursementPayout: jest.fn(), queryAndApply: jest.fn(),
});

describe('loan disbursement service', () => {
  it('encrypts provider destinations with authenticated encryption', () => {
    const clear = { accountNumber: '0123456789', bankCode: '999', accountName: 'Test Farmer' };
    const ciphertext = encryptLoanDisbursementDestination(clear, key);
    expect(ciphertext).not.toContain(clear.accountNumber);
    expect(decryptLoanDisbursementDestination(ciphertext, key)).toEqual(clear);
    expect(() => decryptLoanDisbursementDestination(
      ciphertext, Buffer.alloc(32, 8).toString('base64'),
    )).toThrow(LoanDisbursementValidationError);
  });

  it('validates condition evidence before persistence', () => {
    const storage = gateway();
    const service = new LoanDisbursementService(storage as any, adapter, payouts() as any, key);
    expect(() => service.submitConditionEvidence({
      organizationId, actorId, applicationId,
      conditionId: '00000000-0000-4000-8000-000000000506',
      evidenceReferences: ['invalid reference with spaces'], idempotencyKey: 'condition-evidence-1',
    })).toThrow(LoanDisbursementValidationError);
    expect(storage.submitConditionEvidence).not.toHaveBeenCalled();
  });

  it('validates and encrypts a proposed destination without passing cleartext to storage', async () => {
    const storage = gateway();
    storage.proposeDestination.mockResolvedValue({ destination: { state: 'proposed' } });
    const provider = adapter();
    const routing = payouts();
    const service = new LoanDisbursementService(storage as any, () => provider, routing as any, key);
    await service.proposeDestination({
      organizationId, actorId, applicationId, accountNumber: '0123456789', bankCode: '999',
      idempotencyKey: 'destination-proposal-1',
    });
    expect(routing.assertRoutingEnabled).toHaveBeenCalledWith(provider, organizationId, actorId);
    const command = storage.proposeDestination.mock.calls[0][0];
    expect(command.destinationCiphertext).not.toContain('0123456789');
    expect(command.destinationMasked).toBe('******6789');
    expect(command.verificationSnapshot).not.toHaveProperty('accountNumber');
  });

  it('opens the destination only for provider submission and strips ciphertext from output', async () => {
    const storage = gateway();
    const destination = { accountNumber: '0123456789', bankCode: '999', accountName: 'Test Farmer' };
    storage.beginDisbursement.mockResolvedValue({
      disbursement: { id: 'disbursement' },
      payout: { id: 'payout', source_type: 'loan_disbursement', state: 'reserved' },
      destination_ciphertext: encryptLoanDisbursementDestination(destination, key),
    });
    const routing = payouts();
    routing.submitLoanDisbursementPayout.mockResolvedValue({ state: 'processing' });
    const service = new LoanDisbursementService(storage as any, adapter, routing as any, key);
    const result: any = await service.beginDisbursement({
      organizationId, actorId, applicationId, destinationId, correlationId,
      idempotencyKey: 'loan-disbursement-begin-1',
    });
    expect(routing.submitLoanDisbursementPayout).toHaveBeenCalledWith(expect.objectContaining({
      organizationId, actorId, destination,
    }));
    expect(result.destination_ciphertext).toBeUndefined();
    expect(result.payout.state).toBe('processing');
  });

  it('syncs only a tenant-scoped disbursement payout', async () => {
    const storage = gateway();
    storage.getDisbursement.mockResolvedValue({ payout_id: 'provider-payout-id' });
    const routing = payouts();
    routing.queryAndApply.mockResolvedValue({ state: 'succeeded' });
    const service = new LoanDisbursementService(storage as any, adapter, routing as any, key);
    await expect(service.syncDisbursement({
      organizationId, actorId, applicationId,
      disbursementId: '00000000-0000-4000-8000-000000000507',
    })).resolves.toEqual({ state: 'succeeded' });
    expect(routing.queryAndApply).toHaveBeenCalledWith('provider-payout-id');
  });
});
