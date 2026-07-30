import crypto from 'crypto';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export interface BookingDomainNotification {
  id: string;
  recipient_organization_id: string;
  booking_id: string;
  event_type: string;
  attempt_count: number;
  max_attempts: number;
}

export interface BookingNotificationOutboxRepository {
  claim(input: {
    workerId: string;
    now: string;
    leaseSeconds: number;
    limit: number;
  }): Promise<BookingDomainNotification[]>;
  deliver(input: {
    notificationId: string;
    workerId: string;
    deliveredAt: string;
  }): Promise<void>;
  fail(input: {
    notificationId: string;
    workerId: string;
    failureCode: string;
    failedAt: string;
  }): Promise<void>;
}

export class SupabaseBookingNotificationOutboxRepository
implements BookingNotificationOutboxRepository {
  async claim(input: {
    workerId: string;
    now: string;
    leaseSeconds: number;
    limit: number;
  }): Promise<BookingDomainNotification[]> {
    const { data, error } = await supabase.rpc('claim_booking_domain_notifications', {
      p_worker_id: input.workerId,
      p_now: input.now,
      p_lease_seconds: input.leaseSeconds,
      p_limit: input.limit,
    });
    if (error) throw error;
    return (data ?? []) as BookingDomainNotification[];
  }

  async deliver(input: {
    notificationId: string;
    workerId: string;
    deliveredAt: string;
  }): Promise<void> {
    const { error } = await supabase.rpc('deliver_booking_domain_notification', {
      p_notification_id: input.notificationId,
      p_worker_id: input.workerId,
      p_delivered_at: input.deliveredAt,
    });
    if (error) throw error;
  }

  async fail(input: {
    notificationId: string;
    workerId: string;
    failureCode: string;
    failedAt: string;
  }): Promise<void> {
    const { error } = await supabase.rpc('fail_booking_domain_notification', {
      p_notification_id: input.notificationId,
      p_worker_id: input.workerId,
      p_failure_code: input.failureCode,
      p_failed_at: input.failedAt,
    });
    if (error) throw error;
  }
}

export class BookingNotificationOutboxWorker {
  constructor(
    private readonly repository: BookingNotificationOutboxRepository,
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `booking-notification-${crypto.randomUUID()}`,
  ) {}

  async runOnce(limit = 50): Promise<{
    claimed: number;
    delivered: number;
    failed: number;
  }> {
    const claimed = await this.repository.claim({
      workerId: this.workerId,
      now: this.clock().toISOString(),
      leaseSeconds: 60,
      limit,
    });
    let delivered = 0;
    let failed = 0;
    for (const notification of claimed) {
      try {
        await this.repository.deliver({
          notificationId: notification.id,
          workerId: this.workerId,
          deliveredAt: this.clock().toISOString(),
        });
        delivered += 1;
      } catch {
        failed += 1;
        try {
          await this.repository.fail({
            notificationId: notification.id,
            workerId: this.workerId,
            failureCode: 'DELIVERY_FAILED',
            failedAt: this.clock().toISOString(),
          });
        } catch {
          logger.error('Unable to persist booking notification delivery failure', {
            notificationId: notification.id,
          });
        }
      }
    }
    return { claimed: claimed.length, delivered, failed };
  }
}

export const bookingNotificationOutboxWorker = new BookingNotificationOutboxWorker(
  new SupabaseBookingNotificationOutboxRepository(),
);
