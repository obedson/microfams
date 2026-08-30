import {
  ProviderEventDrainGateway,
  ProviderEventDrainWorker,
} from '../services/providerEventDrainService.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';

const executionRepository = (): jest.Mocked<DurableJobExecutionRepository> => ({
  claim: jest.fn(),
  complete: jest.fn(),
  fail: jest.fn(),
});

const gateway = (): jest.Mocked<ProviderEventDrainGateway> => ({
  listPaymentEventIds: jest.fn(),
  listPayoutEventIds: jest.fn(),
  processPaymentEvent: jest.fn(),
  processPayoutEvent: jest.fn(),
});

describe('ProviderEventDrainWorker', () => {
  const now = new Date('2026-08-30T15:42:37.000Z');
  const clock = () => now;

  it('does not inspect provider queues when another worker owns the job lease', async () => {
    const executions = executionRepository();
    const events = gateway();
    executions.claim.mockResolvedValue(null);
    const worker = new ProviderEventDrainWorker(
      executions, events, clock, 'provider-event-worker-test',
    );

    await expect(worker.runOnce()).resolves.toEqual({
      claimed: false,
      paymentEvents: 0,
      payoutEvents: 0,
      processed: 0,
      failed: 0,
    });
    expect(events.listPaymentEventIds).not.toHaveBeenCalled();
    expect(events.listPayoutEventIds).not.toHaveBeenCalled();
    expect(executions.claim).toHaveBeenCalledWith({
      jobKey: 'financial.provider-event-drain',
      scheduledFor: '2026-08-30T15:42:00.000Z',
      workerId: 'provider-event-worker-test',
      now: now.toISOString(),
      leaseSeconds: 120,
      maxAttempts: 5,
    });
  });

  it('drains payment and payout events and records aggregate completion evidence', async () => {
    const executions = executionRepository();
    const events = gateway();
    executions.claim.mockResolvedValue({
      id: 'execution-1',
      attempt_count: 1,
      max_attempts: 5,
    });
    events.listPaymentEventIds.mockResolvedValue(['payment-1', 'payment-2']);
    events.listPayoutEventIds.mockResolvedValue(['payout-1']);
    events.processPaymentEvent.mockRejectedValueOnce(
      new Error('synthetic payment failure'),
    );
    const worker = new ProviderEventDrainWorker(
      executions, events, clock, 'provider-event-worker-test',
    );

    await expect(worker.runOnce(25)).resolves.toEqual({
      claimed: true,
      paymentEvents: 2,
      payoutEvents: 1,
      processed: 2,
      failed: 1,
    });
    expect(events.listPaymentEventIds).toHaveBeenCalledWith(25);
    expect(events.listPayoutEventIds).toHaveBeenCalledWith(25);
    expect(events.processPaymentEvent).toHaveBeenCalledTimes(2);
    expect(events.processPayoutEvent).toHaveBeenCalledWith('payout-1');
    expect(executions.complete).toHaveBeenCalledWith({
      executionId: 'execution-1',
      workerId: 'provider-event-worker-test',
      completedAt: now.toISOString(),
      result: {
        paymentEvents: 2,
        payoutEvents: 1,
        processed: 2,
        failed: 1,
      },
    });
    expect(executions.fail).not.toHaveBeenCalled();
  });

  it('records retry evidence when queue selection fails', async () => {
    const executions = executionRepository();
    const events = gateway();
    executions.claim.mockResolvedValue({
      id: 'execution-2',
      attempt_count: 1,
      max_attempts: 5,
    });
    events.listPaymentEventIds.mockRejectedValue(
      new Error('provider event store unavailable'),
    );
    const worker = new ProviderEventDrainWorker(
      executions, events, clock, 'provider-event-worker-test',
    );

    await expect(worker.runOnce()).rejects.toThrow('provider event store unavailable');
    expect(executions.fail).toHaveBeenCalledWith({
      executionId: 'execution-2',
      workerId: 'provider-event-worker-test',
      failureCode: 'PROVIDER_EVENT_DRAIN_FAILED',
      failedAt: now.toISOString(),
    });
    expect(events.listPayoutEventIds).not.toHaveBeenCalled();
  });

  it('rejects unbounded batch sizes before claiming work', async () => {
    const executions = executionRepository();
    const events = gateway();
    const worker = new ProviderEventDrainWorker(executions, events, clock);

    await expect(worker.runOnce(0)).rejects.toThrow(
      'Provider event drain limit is invalid',
    );
    expect(executions.claim).not.toHaveBeenCalled();
  });
});
