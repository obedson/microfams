import { InvestmentRefundReversalGateway, InvestmentRefundReversalService } from '../domains/financial/investmentRefundReversalService.js';

const proposal = {
  organizationId: '00000000-0000-4000-8000-000000000101', actorId: '00000000-0000-4000-8000-000000000102',
  obligationId: '00000000-0000-4000-8000-000000000103', providerName: ' Deterministic ',
  providerEnvironment: 'deterministic' as const, providerReversalReference: ' REV-001 ', providerEventHash: 'a'.repeat(64),
  amountMinor: 100000, currency: ' ngn ', occurredAt: '2026-10-05T00:00:00Z',
  reason: ' Verified provider reversal restored the refund liability. ', evidenceReferences: ['provider:event:001'],
  correlationId: '00000000-0000-4000-8000-000000000104', idempotencyKey: 'inv-refund-reversal-001',
};
const gateway = (): jest.Mocked<InvestmentRefundReversalGateway> => ({ propose: jest.fn(), decide: jest.fn() });

describe('InvestmentRefundReversalService', () => {
  it('normalizes and delegates exact provider reversal evidence', async () => {
    const g = gateway(); g.propose.mockResolvedValue({ reversal: { state: 'proposed' } });
    await expect(new InvestmentRefundReversalService(g).propose(proposal)).resolves.toEqual({ reversal: { state: 'proposed' } });
    expect(g.propose).toHaveBeenCalledWith(expect.objectContaining({
      providerName: 'deterministic', providerReversalReference: 'REV-001', currency: 'NGN',
      reason: 'Verified provider reversal restored the refund liability.',
    }));
  });
  it('delegates an independent checker decision', async () => {
    const g = gateway(); g.decide.mockResolvedValue({ reversal: { state: 'approved' } });
    const decision = { organizationId: proposal.organizationId, actorId: proposal.actorId,
      reversalId: '00000000-0000-4000-8000-000000000105', decision: 'approve' as const,
      reviewReason: ' Independent checker verified the provider reversal. ',
      correlationId: proposal.correlationId, idempotencyKey: 'inv-refund-reversal-decision-001' };
    await expect(new InvestmentRefundReversalService(g).decide(decision)).resolves.toEqual({ reversal: { state: 'approved' } });
    expect(g.decide).toHaveBeenCalledWith(expect.objectContaining({ reviewReason: 'Independent checker verified the provider reversal.' }));
  });
  it.each([
    { ...proposal, amountMinor: 0 }, { ...proposal, providerEventHash: 'bad' },
    { ...proposal, evidenceReferences: [] }, { ...proposal, providerReversalReference: 'x' },
  ])('rejects incomplete reversal evidence', (invalid) => {
    expect(() => new InvestmentRefundReversalService(gateway()).propose(invalid as any)).toThrow('invalid');
  });
});
