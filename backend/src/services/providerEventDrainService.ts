import crypto from 'crypto';
import { paymentService } from '../domains/financial/paymentService.js';
import { payoutService } from '../domains/financial/payoutService.js';
import {
  DurableJobExecutionRepository,
  SupabaseDurableJobExecutionRepository,
} from './durableJobExecutionService.js';
import { logger } from '../utils/logger.js';
import { supabase } from '../utils/supabase.js';

const JOB_KEY = 'financial.provider-event-drain';
const scheduledMinute = (date: Date): string => new Date(
  Math.floor(date.getTime() / 60_000) * 60_000,
).toISOString();

export interface ProviderEventDrainGateway {
  listPaymentEventIds(limit: number): Promise<string[]>;
  listPayoutEventIds(limit: number): Promise<string[]>;
  processPaymentEvent(eventId: string): Promise<void>;
  processPayoutEvent(eventId: string): Promise<void>;
}

export interface ProviderEventDrainResult {
  claimed: boolean;
  paymentEvents: number;
  payoutEvents: number;
  processed: number;
  failed: number;
}

export class SupabaseProviderEventDrainGateway
implements ProviderEventDrainGateway {
  async listPaymentEventIds(limit: number): Promise<string[]> {
    const { data, error } = await supabase
      .from('payment_provider_events')
      .select('id')
      .eq('processing_state', 'received')
      .order('received_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    return (data ?? []).map((event: { id: string }) => event.id);
  }

  async listPayoutEventIds(limit: number): Promise<string[]> {
    const { data, error } = await supabase
      .from('provider_events')
      .select('id')
      .eq('processing_state', 'received')
      .order('received_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    return (data ?? []).map((event: { id: string }) => event.id);
  }

  async processPaymentEvent(eventId: string): Promise<void> {
    await paymentService.processProviderEvent(eventId);
  }

  async processPayoutEvent(eventId: string): Promise<void> {
    await payoutService.processProviderEvent(eventId);
  }
}

export class ProviderEventDrainWorker {
  constructor(
    private readonly executions: DurableJobExecutionRepository,
    private readonly gateway: ProviderEventDrainGateway,
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `provider-event-drain-${crypto.randomUUID()}`,
  ) {}

  async runOnce(limit = 50): Promise<ProviderEventDrainResult> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) {
      throw new Error('Provider event drain limit is invalid');
    }
    const startedAt = this.clock();
    const execution = await this.executions.claim({
      jobKey: JOB_KEY,
      scheduledFor: scheduledMinute(startedAt),
      workerId: this.workerId,
      now: startedAt.toISOString(),
      leaseSeconds: 120,
      maxAttempts: 5,
    });
    if (!execution) {
      return {
        claimed: false,
        paymentEvents: 0,
        payoutEvents: 0,
        processed: 0,
        failed: 0,
      };
    }

    try {
      const paymentEventIds = await this.gateway.listPaymentEventIds(limit);
      const payoutEventIds = await this.gateway.listPayoutEventIds(limit);
      let processed = 0;
      let failed = 0;

      for (const eventId of paymentEventIds) {
        try {
          await this.gateway.processPaymentEvent(eventId);
          processed += 1;
        } catch (error) {
          failed += 1;
          logger.error('Failed to process payment provider event', {
            eventId,
            error: error instanceof Error ? error.message : 'Unknown error',
          });
        }
      }
      for (const eventId of payoutEventIds) {
        try {
          await this.gateway.processPayoutEvent(eventId);
          processed += 1;
        } catch (error) {
          failed += 1;
          logger.error('Failed to process payout provider event', {
            eventId,
            error: error instanceof Error ? error.message : 'Unknown error',
          });
        }
      }

      await this.executions.complete({
        executionId: execution.id,
        workerId: this.workerId,
        completedAt: this.clock().toISOString(),
        result: {
          paymentEvents: paymentEventIds.length,
          payoutEvents: payoutEventIds.length,
          processed,
          failed,
        },
      });
      return {
        claimed: true,
        paymentEvents: paymentEventIds.length,
        payoutEvents: payoutEventIds.length,
        processed,
        failed,
      };
    } catch (error) {
      const failedAt = this.clock().toISOString();
      try {
        await this.executions.fail({
          executionId: execution.id,
          workerId: this.workerId,
          failureCode: 'PROVIDER_EVENT_DRAIN_FAILED',
          failedAt,
        });
      } catch (failureError) {
        logger.error('Unable to persist provider event drain failure', {
          executionId: execution.id,
          error: failureError instanceof Error ? failureError.message : 'Unknown error',
        });
      }
      throw error;
    }
  }
}

export const providerEventDrainWorker = new ProviderEventDrainWorker(
  new SupabaseDurableJobExecutionRepository(),
  new SupabaseProviderEventDrainGateway(),
);
