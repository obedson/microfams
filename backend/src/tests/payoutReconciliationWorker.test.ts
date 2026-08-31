import { PayoutReconciliationGateway, PayoutReconciliationWorker } from '../services/payoutReconciliationWorker.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
const repo = (): jest.Mocked<DurableJobExecutionRepository> => ({ claim: jest.fn(), complete: jest.fn(), fail: jest.fn() });
const gateway = (): jest.Mocked<PayoutReconciliationGateway> => ({ listPayoutIds: jest.fn(), reconcilePayout: jest.fn() });
describe('PayoutReconciliationWorker', () => {
  const now = new Date('2026-08-30T19:22:42.000Z');
  it('skips when another worker owns the lease', async () => {
    const executions = repo(); const events = gateway(); executions.claim.mockResolvedValue(null);
    const worker = new PayoutReconciliationWorker(executions, events, () => now, 'payout-worker-test');
    await expect(worker.runOnce()).resolves.toEqual({ claimed: false, candidates: 0, processed: 0, failed: 0 });
    expect(events.listPayoutIds).not.toHaveBeenCalled();
  });
  it('reconciles candidates and records aggregate evidence', async () => {
    const executions = repo(); const events = gateway();
    executions.claim.mockResolvedValue({ id: 'execution-1', attempt_count: 1, max_attempts: 5 });
    events.listPayoutIds.mockResolvedValue(['payout-1', 'payout-2']); events.reconcilePayout.mockRejectedValueOnce(new Error('synthetic'));
    const worker = new PayoutReconciliationWorker(executions, events, () => now, 'payout-worker-test');
    await expect(worker.runOnce(25)).resolves.toEqual({ claimed: true, candidates: 2, processed: 1, failed: 1 });
    expect(executions.complete).toHaveBeenCalledWith(expect.objectContaining({ executionId: 'execution-1', result: { candidates: 2, processed: 1, failed: 1 } }));
  });
  it('persists retry evidence when selection fails', async () => {
    const executions = repo(); const events = gateway(); executions.claim.mockResolvedValue({ id: 'execution-2', attempt_count: 1, max_attempts: 5 }); events.listPayoutIds.mockRejectedValue(new Error('unavailable'));
    const worker = new PayoutReconciliationWorker(executions, events, () => now, 'payout-worker-test');
    await expect(worker.runOnce()).rejects.toThrow('unavailable');
    expect(executions.fail).toHaveBeenCalledWith(expect.objectContaining({ executionId: 'execution-2', failureCode: 'PAYOUT_RECONCILIATION_FAILED' }));
  });
});
