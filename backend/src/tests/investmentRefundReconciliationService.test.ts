import {
  InvestmentRefundReconciliationGateway,
  InvestmentRefundReconciliationService,
} from '../domains/financial/investmentRefundReconciliationService.js';

const command = {
  organizationId: '00000000-0000-4000-8000-000000000101',
  actorId: '00000000-0000-4000-8000-000000000102',
  providerName: ' Deterministic ',
  providerEnvironment: 'deterministic' as const,
  sourceHash: 'a'.repeat(64),
  idempotencyKey: 'inv-refund-reconciliation-001',
  periodStart: '2026-10-01T00:00:00Z',
  periodEnd: '2026-10-03T00:00:00Z',
  providerItems: [{
    internalReference: ' investment-refund-00000000-0000-4000-8000-000000000103 ',
    providerReference: ' DET-REF-001 ',
    status: 'succeeded' as const,
    amountMinor: 100000,
    currency: ' ngn ',
    occurredAt: '2026-10-02T00:09:00Z',
  }],
};

const gateway = (): jest.Mocked<InvestmentRefundReconciliationGateway> => ({ run: jest.fn() });

describe('InvestmentRefundReconciliationService', () => {
  it('normalizes provider evidence and delegates one durable batch command', async () => {
    const g = gateway();
    g.run.mockResolvedValue({ run: { id: 'run-1' }, matched_count: 1, exception_count: 0 });
    await expect(new InvestmentRefundReconciliationService(g).run(command)).resolves.toEqual({
      run: { id: 'run-1' }, matched_count: 1, exception_count: 0,
    });
    expect(g.run).toHaveBeenCalledWith(expect.objectContaining({
      providerName: 'deterministic',
      providerItems: [expect.objectContaining({
        internalReference: 'investment-refund-00000000-0000-4000-8000-000000000103',
        providerReference: 'DET-REF-001', currency: 'NGN', amountMinor: 100000,
      })],
    }));
  });

  it.each([
    { ...command, sourceHash: 'bad' },
    { ...command, periodEnd: command.periodStart },
    { ...command, providerItems: [{ ...command.providerItems[0], amountMinor: 0 }] },
    { ...command, providerItems: [{ ...command.providerItems[0], internalReference: 'payment-1' }] },
  ])('rejects malformed commands before persistence', async (invalid) => {
    const g = gateway();
    expect(() => new InvestmentRefundReconciliationService(g).run(invalid as any)).toThrow('invalid');
    expect(g.run).not.toHaveBeenCalled();
  });

  it('allows an empty authoritative provider batch so missing-provider evidence can be classified', async () => {
    const g = gateway(); g.run.mockResolvedValue({ exception_count: 1 });
    await expect(new InvestmentRefundReconciliationService(g).run({ ...command, providerItems: [] }))
      .resolves.toEqual({ exception_count: 1 });
  });
});
