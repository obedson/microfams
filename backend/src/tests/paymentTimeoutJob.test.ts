import { PaymentTimeoutJob } from '../jobs/paymentTimeoutJob.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';

jest.mock('../utils/audit.js', () => ({
  logAudit: jest.fn().mockResolvedValue(undefined),
}));

const repository = (): jest.Mocked<DurableJobExecutionRepository> => ({
  claim: jest.fn(),
  complete: jest.fn(),
  fail: jest.fn(),
});

describe('PaymentTimeoutJob', () => {
  const now = new Date('2026-08-30T10:37:15.000Z');
  const clock = () => now;

  it('does no payment work when another process owns the hourly lease', async () => {
    const executions = repository();
    executions.claim.mockResolvedValue(null);
    const processTimeouts = jest.fn();
    const job = new PaymentTimeoutJob(
      executions, processTimeouts, clock, 'payment-timeout-worker-test',
    );

    await expect(job.runOnce()).resolves.toEqual({
      claimed: false,
      succeeded: false,
      processed: 0,
      cancelled: 0,
      deferred: 0,
      errors: 0,
    });
    expect(processTimeouts).not.toHaveBeenCalled();
    expect(executions.claim).toHaveBeenCalledWith({
      jobKey: 'payments.timeout-cancellation',
      scheduledFor: '2026-08-30T10:00:00.000Z',
      workerId: 'payment-timeout-worker-test',
      now: now.toISOString(),
      leaseSeconds: 900,
      maxAttempts: 5,
    });
  });

  it('records durable completion evidence for the claimed schedule slot', async () => {
    const executions = repository();
    executions.claim.mockResolvedValue({
      id: 'execution-1',
      attempt_count: 1,
      max_attempts: 5,
    });
    const processTimeouts = jest.fn().mockResolvedValue({
      processed: 5,
      cancelled: 3,
      deferred: 1,
      errors: ['Payment one: provider unavailable'],
    });
    const job = new PaymentTimeoutJob(
      executions, processTimeouts, clock, 'payment-timeout-worker-test',
    );

    await expect(job.runOnce()).resolves.toEqual({
      claimed: true,
      succeeded: true,
      processed: 5,
      cancelled: 3,
      deferred: 1,
      errors: 1,
    });
    expect(executions.complete).toHaveBeenCalledWith({
      executionId: 'execution-1',
      workerId: 'payment-timeout-worker-test',
      completedAt: now.toISOString(),
      result: {
        processed: 5,
        cancelled: 3,
        deferred: 1,
        errorCount: 1,
      },
    });
    expect(executions.fail).not.toHaveBeenCalled();
  });

  it('persists a retryable failure instead of losing a claimed run', async () => {
    const executions = repository();
    executions.claim.mockResolvedValue({
      id: 'execution-2',
      attempt_count: 1,
      max_attempts: 5,
    });
    const processTimeouts = jest.fn().mockRejectedValue(
      new Error('payment recovery unavailable'),
    );
    const job = new PaymentTimeoutJob(
      executions, processTimeouts, clock, 'payment-timeout-worker-test',
    );

    await expect(job.runOnce()).resolves.toEqual({
      claimed: true,
      succeeded: false,
      processed: 0,
      cancelled: 0,
      deferred: 0,
      errors: 1,
    });
    expect(executions.fail).toHaveBeenCalledWith({
      executionId: 'execution-2',
      workerId: 'payment-timeout-worker-test',
      failureCode: 'PAYMENT_TIMEOUT_JOB_FAILED',
      failedAt: now.toISOString(),
    });
  });
});
