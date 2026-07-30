import {
  BookingNotificationOutboxRepository,
  BookingNotificationOutboxWorker,
} from '../services/bookingNotificationOutboxService.js';

const repository = (): jest.Mocked<BookingNotificationOutboxRepository> => ({
  claim: jest.fn(),
  deliver: jest.fn(),
  fail: jest.fn(),
});

describe('booking notification outbox worker', () => {
  const now = new Date('2026-07-30T09:00:00.000Z');
  const clock = () => now;

  it('claims with a deterministic clock and delivers each leased event', async () => {
    const repo = repository();
    repo.claim.mockResolvedValue([
      {
        id: 'event-1',
        recipient_organization_id: 'org-1',
        booking_id: 'booking-1',
        event_type: 'refund_state',
        attempt_count: 1,
        max_attempts: 8,
      },
      {
        id: 'event-2',
        recipient_organization_id: 'org-2',
        booking_id: 'booking-2',
        event_type: 'payout_state',
        attempt_count: 1,
        max_attempts: 8,
      },
    ]);
    const worker = new BookingNotificationOutboxWorker(
      repo, clock, 'booking-worker-test',
    );

    await expect(worker.runOnce(20)).resolves.toEqual({
      claimed: 2,
      delivered: 2,
      failed: 0,
    });
    expect(repo.claim).toHaveBeenCalledWith({
      workerId: 'booking-worker-test',
      now: now.toISOString(),
      leaseSeconds: 60,
      limit: 20,
    });
    expect(repo.deliver).toHaveBeenCalledTimes(2);
    expect(repo.fail).not.toHaveBeenCalled();
  });

  it('records bounded retry evidence without blocking other deliveries', async () => {
    const repo = repository();
    repo.claim.mockResolvedValue([
      {
        id: 'event-fails',
        recipient_organization_id: 'org-1',
        booking_id: 'booking-1',
        event_type: 'reversal',
        attempt_count: 3,
        max_attempts: 8,
      },
      {
        id: 'event-succeeds',
        recipient_organization_id: 'org-2',
        booking_id: 'booking-2',
        event_type: 'recovery',
        attempt_count: 1,
        max_attempts: 8,
      },
    ]);
    repo.deliver.mockRejectedValueOnce(new Error('synthetic delivery failure'));
    const worker = new BookingNotificationOutboxWorker(
      repo, clock, 'booking-worker-test',
    );

    await expect(worker.runOnce()).resolves.toEqual({
      claimed: 2,
      delivered: 1,
      failed: 1,
    });
    expect(repo.fail).toHaveBeenCalledWith({
      notificationId: 'event-fails',
      workerId: 'booking-worker-test',
      failureCode: 'DELIVERY_FAILED',
      failedAt: now.toISOString(),
    });
    expect(repo.deliver).toHaveBeenCalledWith(expect.objectContaining({
      notificationId: 'event-succeeds',
    }));
  });

  it('does no delivery work when the lease batch is empty', async () => {
    const repo = repository();
    repo.claim.mockResolvedValue([]);
    const worker = new BookingNotificationOutboxWorker(
      repo, clock, 'booking-worker-test',
    );

    await expect(worker.runOnce()).resolves.toEqual({
      claimed: 0,
      delivered: 0,
      failed: 0,
    });
    expect(repo.deliver).not.toHaveBeenCalled();
    expect(repo.fail).not.toHaveBeenCalled();
  });

  it('continues the batch when retry evidence cannot be persisted', async () => {
    const repo = repository();
    repo.claim.mockResolvedValue([
      {
        id: 'event-fails',
        recipient_organization_id: 'org-1',
        booking_id: 'booking-1',
        event_type: 'reversal',
        attempt_count: 1,
        max_attempts: 8,
      },
      {
        id: 'event-succeeds',
        recipient_organization_id: 'org-2',
        booking_id: 'booking-2',
        event_type: 'recovery',
        attempt_count: 1,
        max_attempts: 8,
      },
    ]);
    repo.deliver.mockRejectedValueOnce(new Error('synthetic delivery failure'));
    repo.fail.mockRejectedValueOnce(new Error('synthetic retry persistence failure'));
    const worker = new BookingNotificationOutboxWorker(
      repo, clock, 'booking-worker-test',
    );

    await expect(worker.runOnce()).resolves.toEqual({
      claimed: 2,
      delivered: 1,
      failed: 1,
    });
    expect(repo.deliver).toHaveBeenCalledWith(expect.objectContaining({
      notificationId: 'event-succeeds',
    }));
  });
});
