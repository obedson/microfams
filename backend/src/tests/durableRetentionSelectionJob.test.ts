import { DurableRetentionSelectionJob, RetentionSelectionRunner } from '../jobs/durableRetentionSelectionJob.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
const repo = (): jest.Mocked<DurableJobExecutionRepository> => ({ claim: jest.fn(), complete: jest.fn(), fail: jest.fn() });
const runner = (): jest.Mocked<RetentionSelectionRunner> => ({ runOnce: jest.fn() });
describe('DurableRetentionSelectionJob', () => {
  const now = new Date('2026-08-31T02:22:42.000Z');
  it('does not inspect retention runs without the lease', async () => {
    const executions = repo(); const retention = runner(); executions.claim.mockResolvedValue(null);
    await expect(new DurableRetentionSelectionJob(executions, retention, () => now, 'retention-worker-test').runOnce()).resolves.toEqual({ claimed: false, scanned: 0, completed: 0, failed: 0 });
    expect(retention.runOnce).not.toHaveBeenCalled();
  });
  it('records aggregate dry-run selection evidence', async () => {
    const executions = repo(); const retention = runner(); executions.claim.mockResolvedValue({ id: 'execution-1', attempt_count: 1, max_attempts: 5 }); retention.runOnce.mockResolvedValue({ scanned: 3, completed: 2, failed: 1 });
    await expect(new DurableRetentionSelectionJob(executions, retention, () => now, 'retention-worker-test').runOnce(10)).resolves.toEqual({ claimed: true, scanned: 3, completed: 2, failed: 1 });
    expect(retention.runOnce).toHaveBeenCalledWith(10);
    expect(executions.complete).toHaveBeenCalledWith(expect.objectContaining({ result: { scanned: 3, completed: 2, failed: 1 } }));
  });
  it('persists retry evidence when selection cannot start', async () => {
    const executions = repo(); const retention = runner(); executions.claim.mockResolvedValue({ id: 'execution-2', attempt_count: 1, max_attempts: 5 }); retention.runOnce.mockRejectedValue(new Error('unavailable'));
    await expect(new DurableRetentionSelectionJob(executions, retention, () => now, 'retention-worker-test').runOnce()).rejects.toThrow('unavailable');
    expect(executions.fail).toHaveBeenCalledWith(expect.objectContaining({ failureCode: 'RETENTION_SELECTION_JOB_FAILED' }));
  });
});
