import { NubanRetryGateway, NubanRetryWorker } from '../services/nubanRetryWorker.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
const repo = (): jest.Mocked<DurableJobExecutionRepository> => ({ claim: jest.fn(), complete: jest.fn(), fail: jest.fn() });
const gateway = (): jest.Mocked<NubanRetryGateway> => ({ listPending: jest.fn(), provision: jest.fn(), markFailure: jest.fn() });
describe('NubanRetryWorker', () => {
  const now = new Date('2026-08-31T01:10:00.000Z');
  it('does not inspect provider work without the lease', async () => {
    const executions = repo(); const provider = gateway(); executions.claim.mockResolvedValue(null);
    await expect(new NubanRetryWorker(executions, provider, () => now, 'nuban-worker-test').runOnce()).resolves.toEqual({ claimed: false, candidates: 0, attempted: 0, provisioned: 0, failed: 0, deferred: 0 });
    expect(provider.listPending).not.toHaveBeenCalled();
  });
  it('preserves exponential backoff and records aggregate evidence', async () => {
    const executions = repo(); const provider = gateway(); executions.claim.mockResolvedValue({ id: 'execution-1', attempt_count: 1, max_attempts: 5 });
    provider.listPending.mockResolvedValue([
      { id: 'gva-1', groupId: 'group-1', organizationId: 'org-1', groupName: 'One', retryCount: 0, updatedAt: '2026-08-31T01:00:00.000Z' },
      { id: 'gva-2', groupId: 'group-2', organizationId: 'org-1', groupName: 'Two', retryCount: 2, updatedAt: '2026-08-31T01:09:00.000Z' },
    ]);
    provider.provision.mockRejectedValueOnce(new Error('provider down'));
    await expect(new NubanRetryWorker(executions, provider, () => now, 'nuban-worker-test').runOnce()).resolves.toEqual({ claimed: true, candidates: 2, attempted: 1, provisioned: 0, failed: 1, deferred: 1 });
    expect(provider.markFailure).toHaveBeenCalledWith(expect.objectContaining({ id: 'gva-1' }), now.toISOString());
    expect(executions.complete).toHaveBeenCalledWith(expect.objectContaining({ result: { candidates: 2, attempted: 1, provisioned: 0, failed: 1, deferred: 1 } }));
  });
  it('persists retry evidence when candidate selection fails', async () => {
    const executions = repo(); const provider = gateway(); executions.claim.mockResolvedValue({ id: 'execution-2', attempt_count: 1, max_attempts: 5 }); provider.listPending.mockRejectedValue(new Error('unavailable'));
    await expect(new NubanRetryWorker(executions, provider, () => now, 'nuban-worker-test').runOnce()).rejects.toThrow('unavailable');
    expect(executions.fail).toHaveBeenCalledWith(expect.objectContaining({ failureCode: 'NUBAN_RETRY_FAILED' }));
  });
});
