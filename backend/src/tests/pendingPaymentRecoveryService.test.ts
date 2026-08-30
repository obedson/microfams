import {
  PendingPaymentRecoveryGateway,
  PendingPaymentRecoveryWorker,
  RecoverableRefund,
} from '../services/pendingPaymentRecoveryService.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';

const executionRepository = (): jest.Mocked<DurableJobExecutionRepository> => ({
  claim: jest.fn(),
  complete: jest.fn(),
  fail: jest.fn(),
});

const gateway = (): jest.Mocked<PendingPaymentRecoveryGateway> => ({
  listPaymentIds: jest.fn(),
  listRefunds: jest.fn(),
  recoverPayment: jest.fn(),
  recoverRefund: jest.fn(),
});

describe('PendingPaymentRecoveryWorker', () => {
  const now = new Date('2026-08-30T18:37:42.000Z');
  const clock = () => now;

  it('does not inspect financial records when another worker owns the lease', async () => {
    const executions = executionRepository();
    const recovery = gateway();
    executions.claim.mockResolvedValue(null);
    const worker = new PendingPaymentRecoveryWorker(
      executions, recovery, clock, 'pending-payment-recovery-test',
    );

    await expect(worker.runOnce()).resolves.toEqual({
      claimed: false,
      paymentCandidates: 0,
      refundCandidates: 0,
      processed: 0,
      failed: 0,
    });
    expect(recovery.listPaymentIds).not.toHaveBeenCalled();
    expect(recovery.listRefunds).not.toHaveBeenCalled();
    expect(executions.claim).toHaveBeenCalledWith({
      jobKey: 'payments.pending-recovery',
      scheduledFor: '2026-08-30T18:30:00.000Z',
      workerId: 'pending-payment-recovery-test',
      now: now.toISOString(),
      leaseSeconds: 900,
      maxAttempts: 5,
    });
  });

  it('recovers payments and refunds and records aggregate evidence', async () => {
    const executions = executionRepository();
    const recovery = gateway();
    const refunds: RecoverableRefund[] = [
      { id: 'refund-1', organizationId: 'organization-1', state: 'created' },
      { id: 'refund-2', organizationId: 'organization-1', state: 'processing' },
    ];
    executions.claim.mockResolvedValue({
      id: 'execution-1', attempt_count: 1, max_attempts: 5,
    });
    recovery.listPaymentIds.mockResolvedValue(['payment-1', 'payment-2']);
    recovery.listRefunds.mockResolvedValue(refunds);
    recovery.recoverPayment.mockRejectedValueOnce(new Error('synthetic payment failure'));
    const worker = new PendingPaymentRecoveryWorker(
      executions, recovery, clock, 'pending-payment-recovery-test',
    );

    await expect(worker.runOnce(25)).resolves.toEqual({
      claimed: true,
      paymentCandidates: 2,
      refundCandidates: 2,
      processed: 3,
      failed: 1,
    });
    expect(recovery.listPaymentIds).toHaveBeenCalledWith(
      '2026-08-30T18:22:42.000Z', 25,
    );
    expect(recovery.listRefunds).toHaveBeenCalledWith(
      '2026-08-30T18:22:42.000Z', 25,
    );
    expect(recovery.recoverPayment).toHaveBeenCalledTimes(2);
    expect(recovery.recoverRefund).toHaveBeenCalledTimes(2);
    expect(executions.complete).toHaveBeenCalledWith({
      executionId: 'execution-1',
      workerId: 'pending-payment-recovery-test',
      completedAt: now.toISOString(),
      result: {
        paymentCandidates: 2,
        refundCandidates: 2,
        processed: 3,
        failed: 1,
      },
    });
    expect(executions.fail).not.toHaveBeenCalled();
  });

  it('persists retry evidence when candidate selection fails', async () => {
    const executions = executionRepository();
    const recovery = gateway();
    executions.claim.mockResolvedValue({
      id: 'execution-2', attempt_count: 1, max_attempts: 5,
    });
    recovery.listPaymentIds.mockRejectedValue(new Error('payment store unavailable'));
    const worker = new PendingPaymentRecoveryWorker(
      executions, recovery, clock, 'pending-payment-recovery-test',
    );

    await expect(worker.runOnce()).rejects.toThrow('payment store unavailable');
    expect(executions.fail).toHaveBeenCalledWith({
      executionId: 'execution-2',
      workerId: 'pending-payment-recovery-test',
      failureCode: 'PENDING_PAYMENT_RECOVERY_FAILED',
      failedAt: now.toISOString(),
    });
    expect(recovery.listRefunds).not.toHaveBeenCalled();
  });

  it('rejects unbounded batches before claiming financial work', async () => {
    const executions = executionRepository();
    const recovery = gateway();
    const worker = new PendingPaymentRecoveryWorker(executions, recovery, clock);

    await expect(worker.runOnce(201)).rejects.toThrow(
      'Pending payment recovery limit is invalid',
    );
    expect(executions.claim).not.toHaveBeenCalled();
  });
});
