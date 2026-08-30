import crypto from 'crypto';
import cron from 'node-cron';
import { PaymentRecoveryService } from '../services/paymentRecoveryService.js';
import {
  DurableJobExecutionRepository,
  SupabaseDurableJobExecutionRepository,
} from '../services/durableJobExecutionService.js';
import { logAudit } from '../utils/audit.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'payments.timeout-cancellation';
const scheduledHour = (date: Date): string => new Date(
  Math.floor(date.getTime() / (60 * 60 * 1000)) * 60 * 60 * 1000,
).toISOString();

export interface PaymentTimeoutResult {
  claimed: boolean;
  succeeded: boolean;
  processed: number;
  cancelled: number;
  deferred: number;
  errors: number;
}

export class PaymentTimeoutJob {
  constructor(
    private readonly executions: DurableJobExecutionRepository,
    private readonly processTimeoutCancellations = (
      () => PaymentRecoveryService.processTimeoutCancellations()
    ),
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `payment-timeout-${crypto.randomUUID()}`,
  ) {}

  async runOnce(): Promise<PaymentTimeoutResult> {
    const startedAt = this.clock();
    const execution = await this.executions.claim({
      jobKey: JOB_KEY,
      scheduledFor: scheduledHour(startedAt),
      workerId: this.workerId,
      now: startedAt.toISOString(),
      leaseSeconds: 900,
      maxAttempts: 5,
    });
    if (!execution) {
      return {
        claimed: false,
        succeeded: false,
        processed: 0,
        cancelled: 0,
        deferred: 0,
        errors: 0,
      };
    }

    try {
      const results = await this.processTimeoutCancellations();
      const completedAt = this.clock().toISOString();
      await this.executions.complete({
        executionId: execution.id,
        workerId: this.workerId,
        completedAt,
        result: {
          processed: results.processed,
          cancelled: results.cancelled,
          deferred: results.deferred,
          errorCount: results.errors.length,
        },
      });
      try {
        await logAudit({
          user_id: null,
          action: 'payment_timeout_job_executed',
          resource_type: 'system',
          resource_id: 'payment_timeout_job',
          details: {
            processed: results.processed,
            cancelled: results.cancelled,
            deferred: results.deferred,
            error_count: results.errors.length,
            execution_id: execution.id,
            executed_at: completedAt,
          },
        });
      } catch (auditError) {
        logger.error('Unable to write payment timeout completion audit', {
          executionId: execution.id,
          error: auditError instanceof Error ? auditError.message : 'Unknown error',
        });
      }
      if (results.errors.length > 0) {
        logger.warn('Payment timeout job completed with item errors', {
          executionId: execution.id,
          errorCount: results.errors.length,
        });
      }
      return {
        claimed: true,
        succeeded: true,
        processed: results.processed,
        cancelled: results.cancelled,
        deferred: results.deferred,
        errors: results.errors.length,
      };
    } catch (error) {
      const failedAt = this.clock().toISOString();
      try {
        await this.executions.fail({
          executionId: execution.id,
          workerId: this.workerId,
          failureCode: 'PAYMENT_TIMEOUT_JOB_FAILED',
          failedAt,
        });
      } catch (failureError) {
        logger.error('Unable to persist payment timeout job failure', {
          executionId: execution.id,
          error: failureError instanceof Error ? failureError.message : 'Unknown error',
        });
      }
      logger.error('Payment timeout job failed', {
        executionId: execution.id,
        error: error instanceof Error ? error.message : 'Unknown error',
      });
      return {
        claimed: true,
        succeeded: false,
        processed: 0,
        cancelled: 0,
        deferred: 0,
        errors: 1,
      };
    }
  }

  scheduleJob(): void {
    cron.schedule('*/5 * * * *', async () => {
      try {
        await this.runOnce();
      } catch (error) {
        logger.error('Unable to claim payment timeout job execution', {
          error: error instanceof Error ? error.message : 'Unknown error',
        });
      }
    });
    logger.info('Payment timeout job scheduled with durable hourly leases');
  }
}

export const paymentTimeoutJob = new PaymentTimeoutJob(
  new SupabaseDurableJobExecutionRepository(),
);
