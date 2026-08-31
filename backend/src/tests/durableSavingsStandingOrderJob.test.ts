import { DurableSavingsStandingOrderJob, SavingsStandingOrderRunner } from '../jobs/durableSavingsStandingOrderJob.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
const repo = (): jest.Mocked<DurableJobExecutionRepository> => ({ claim: jest.fn(), complete: jest.fn(), fail: jest.fn() });
const runner = (): jest.Mocked<SavingsStandingOrderRunner> => ({ runOnce: jest.fn() });
describe('DurableSavingsStandingOrderJob', () => {
  const now = new Date('2026-08-31T01:23:42.000Z');
  it('does not inspect savings mandates without the lease', async () => {
    const executions = repo(); const savings = runner(); executions.claim.mockResolvedValue(null);
    await expect(new DurableSavingsStandingOrderJob(executions, savings, () => now, 'savings-worker-test').runOnce()).resolves.toEqual({ claimed: false, due: 0, serviced: 0, skipped: 0, errors: 0 });
    expect(savings.runOnce).not.toHaveBeenCalled();
  });
  it('records aggregate servicing evidence', async () => {
    const executions = repo(); const savings = runner(); executions.claim.mockResolvedValue({ id: 'execution-1', attempt_count: 1, max_attempts: 5 }); savings.runOnce.mockResolvedValue({ due: 4, serviced: 2, skipped: 1, errors: 1 });
    await expect(new DurableSavingsStandingOrderJob(executions, savings, () => now, 'savings-worker-test').runOnce(25)).resolves.toEqual({ claimed: true, due: 4, serviced: 2, skipped: 1, errors: 1 });
    expect(savings.runOnce).toHaveBeenCalledWith(25);
    expect(executions.complete).toHaveBeenCalledWith(expect.objectContaining({ result: { due: 4, serviced: 2, skipped: 1, errors: 1 } }));
  });
  it('persists retry evidence when servicing cannot start', async () => {
    const executions = repo(); const savings = runner(); executions.claim.mockResolvedValue({ id: 'execution-2', attempt_count: 1, max_attempts: 5 }); savings.runOnce.mockRejectedValue(new Error('unavailable'));
    await expect(new DurableSavingsStandingOrderJob(executions, savings, () => now, 'savings-worker-test').runOnce()).rejects.toThrow('unavailable');
    expect(executions.fail).toHaveBeenCalledWith(expect.objectContaining({ failureCode: 'SAVINGS_STANDING_ORDER_JOB_FAILED' }));
  });
});
