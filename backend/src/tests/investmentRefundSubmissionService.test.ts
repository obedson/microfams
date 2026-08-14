import {
  InvestmentRefundSubmissionGateway,
  InvestmentRefundSubmissionService,
} from '../domains/financial/investmentRefundSubmissionService.js';

const command = {
  organizationId: '00000000-0000-4000-8000-000000000101',
  actorId: '00000000-0000-4000-8000-000000000102',
  obligationId: '00000000-0000-4000-8000-000000000103',
  correlationId: '00000000-0000-4000-8000-000000000104',
  idempotencyKey: 'investment-refund-submit-001',
};
const prepared = (environment: 'deterministic' | 'sandbox' | 'live' = 'deterministic') => ({
  replayed: false,
  attempt: {
    id: '00000000-0000-4000-8000-000000000105', state: 'prepared',
    provider_name: environment === 'deterministic' ? 'deterministic' : 'paystack',
    provider_environment: environment,
  },
  obligation: { id: command.obligationId, amount_minor: 100000, currency: 'NGN' as const },
  provider_payment_reference: 'SET-ORIGINAL-001',
});
const recoverable = () => ({
  ...prepared(),
  attempt: { ...prepared().attempt, state: 'processing' },
});
const gateway = (): jest.Mocked<InvestmentRefundSubmissionGateway> => ({
  begin: jest.fn(), complete: jest.fn(), prepareRecovery: jest.fn(), completeRecovery: jest.fn(),
});

describe('InvestmentRefundSubmissionService', () => {
  it('submits exact money through the original adapter but does not finalize synchronous success', async () => {
    const g = gateway(); g.begin.mockResolvedValue(prepared());
    g.complete.mockResolvedValue({ attempt: { state: 'processing' } });
    const refund = jest.fn().mockResolvedValue({
      providerReference: 'DET-REF-001', status: 'succeeded', amountMinor: 100000, currency: 'NGN',
    });
    await new InvestmentRefundSubmissionService(g, () => ({ name: 'deterministic', environment: 'deterministic', refund } as any)).submit(command);
    expect(g.complete).toHaveBeenCalledWith(expect.objectContaining({ state: 'processing', providerReportedState: 'succeeded' }));
  });

  it('records ambiguous provider submission as unknown for later recovery', async () => {
    const g = gateway(); g.begin.mockResolvedValue(prepared()); g.complete.mockResolvedValue({});
    await new InvestmentRefundSubmissionService(g, () => ({
      name: 'deterministic', environment: 'deterministic', refund: jest.fn().mockRejectedValue(new Error('timeout')),
    } as any)).submit(command);
    expect(g.complete).toHaveBeenCalledWith(expect.objectContaining({ state: 'unknown', failureCode: 'provider_response_ambiguous' }));
  });

  it('recovers exact provider success and delegates final journal posting to the durable gateway', async () => {
    const g = gateway(); g.prepareRecovery.mockResolvedValue(recoverable());
    g.completeRecovery.mockResolvedValue({ obligation: { state: 'succeeded' } });
    const recoverRefund = jest.fn().mockResolvedValue({
      providerReference: 'DET-REF-001', status: 'succeeded', amountMinor: 100000, currency: 'NGN',
    });
    await expect(new InvestmentRefundSubmissionService(g, () => ({
      name: 'deterministic', environment: 'deterministic', recoverRefund,
    } as any)).recover({ organizationId: command.organizationId, actorId: command.actorId, obligationId: command.obligationId }))
      .resolves.toEqual({ obligation: { state: 'succeeded' } });
    expect(recoverRefund).toHaveBeenCalledWith(expect.objectContaining({
      internalReference: `investment-refund-${recoverable().attempt.id}`,
      providerPaymentReference: 'SET-ORIGINAL-001', amountMinor: 100000, currency: 'NGN',
    }));
    expect(g.completeRecovery).toHaveBeenCalledWith(expect.objectContaining({
      state: 'succeeded', providerReportedState: 'succeeded', providerReference: 'DET-REF-001',
    }));
  });

  it('preserves the liability for missing, ambiguous, or mismatched recovery evidence', async () => {
    const g = gateway(); g.prepareRecovery.mockResolvedValue(recoverable()); g.completeRecovery.mockResolvedValue({});
    await new InvestmentRefundSubmissionService(g, () => ({
      name: 'deterministic', environment: 'deterministic', recoverRefund: jest.fn().mockResolvedValue(undefined),
    } as any)).recover({ organizationId: command.organizationId, actorId: command.actorId, obligationId: command.obligationId });
    expect(g.completeRecovery).toHaveBeenLastCalledWith(expect.objectContaining({ state: 'unknown', failureCode: 'provider_recovery_not_found' }));
    await new InvestmentRefundSubmissionService(g, () => ({
      name: 'deterministic', environment: 'deterministic',
      recoverRefund: jest.fn().mockResolvedValue({ status: 'succeeded', providerReference: 'BAD', amountMinor: 99999, currency: 'NGN' }),
    } as any)).recover({ organizationId: command.organizationId, actorId: command.actorId, obligationId: command.obligationId });
    expect(g.completeRecovery).toHaveBeenLastCalledWith(expect.objectContaining({ state: 'manual_review', failureCode: 'provider_money_mismatch' }));
  });

  it('rejects malformed identities before recovery storage', async () => {
    await expect(new InvestmentRefundSubmissionService(gateway()).recover({
      organizationId: command.organizationId, actorId: command.actorId, obligationId: 'bad',
    })).rejects.toThrow('identity');
  });
});
