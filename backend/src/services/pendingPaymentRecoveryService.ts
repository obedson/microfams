import crypto from 'crypto';
import { paymentService } from '../domains/financial/paymentService.js';
import {
  DurableJobExecutionRepository,
  SupabaseDurableJobExecutionRepository,
} from './durableJobExecutionService.js';
import { logger } from '../utils/logger.js';
import { supabase } from '../utils/supabase.js';

const JOB_KEY = 'payments.pending-recovery';
const FIFTEEN_MINUTES_MS = 15 * 60 * 1000;
const scheduledQuarterHour = (date: Date): string => new Date(
  Math.floor(date.getTime() / FIFTEEN_MINUTES_MS) * FIFTEEN_MINUTES_MS,
).toISOString();

export interface RecoverableRefund {
  id: string;
  organizationId: string;
  state: 'created' | 'submitted' | 'processing';
}

export interface PendingPaymentRecoveryGateway {
  listPaymentIds(olderThan: string, limit: number): Promise<string[]>;
  listRefunds(olderThan: string, limit: number): Promise<RecoverableRefund[]>;
  recoverPayment(paymentId: string): Promise<void>;
  recoverRefund(refund: RecoverableRefund): Promise<void>;
}

export interface PendingPaymentRecoveryResult {
  claimed: boolean;
  paymentCandidates: number;
  refundCandidates: number;
  processed: number;
  failed: number;
}

export class SupabasePendingPaymentRecoveryGateway
implements PendingPaymentRecoveryGateway {
  async listPaymentIds(olderThan: string, limit: number): Promise<string[]> {
    const { data, error } = await supabase
      .from('payments')
      .select('id')
      .in('state', ['requires_action', 'processing'])
      .lt('updated_at', olderThan)
      .order('updated_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    return (data ?? []).map((payment: { id: string }) => payment.id);
  }

  async listRefunds(olderThan: string, limit: number): Promise<RecoverableRefund[]> {
    const { data, error } = await supabase
      .from('payment_refunds')
      .select('id, organization_id, state')
      .in('state', ['created', 'submitted', 'processing'])
      .lt('updated_at', olderThan)
      .order('updated_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    return (data ?? []).map((refund: {
      id: string;
      organization_id: string;
      state: RecoverableRefund['state'];
    }) => ({
      id: refund.id,
      organizationId: refund.organization_id,
      state: refund.state,
    }));
  }

  async recoverPayment(paymentId: string): Promise<void> {
    await paymentService.queryAndApply(paymentId);
  }

  async recoverRefund(refund: RecoverableRefund): Promise<void> {
    if (refund.state === 'created') {
      await paymentService.submitRefund(refund.id, refund.organizationId);
      return;
    }
    await paymentService.queryRefundAndApply(refund.id);
  }
}

export class PendingPaymentRecoveryWorker {
  constructor(
    private readonly executions: DurableJobExecutionRepository,
    private readonly gateway: PendingPaymentRecoveryGateway,
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `pending-payment-recovery-${crypto.randomUUID()}`,
  ) {}

  async runOnce(limit = 50): Promise<PendingPaymentRecoveryResult> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) {
      throw new Error('Pending payment recovery limit is invalid');
    }
    const startedAt = this.clock();
    const execution = await this.executions.claim({
      jobKey: JOB_KEY,
      scheduledFor: scheduledQuarterHour(startedAt),
      workerId: this.workerId,
      now: startedAt.toISOString(),
      leaseSeconds: 900,
      maxAttempts: 5,
    });
    if (!execution) {
      return {
        claimed: false,
        paymentCandidates: 0,
        refundCandidates: 0,
        processed: 0,
        failed: 0,
      };
    }

    try {
      const olderThan = new Date(startedAt.getTime() - FIFTEEN_MINUTES_MS).toISOString();
      const paymentIds = await this.gateway.listPaymentIds(olderThan, limit);
      const refunds = await this.gateway.listRefunds(olderThan, limit);
      let processed = 0;
      let failed = 0;

      for (const paymentId of paymentIds) {
        try {
          await this.gateway.recoverPayment(paymentId);
          processed += 1;
        } catch (error) {
          failed += 1;
          logger.error('Failed to recover pending payment', {
            paymentId,
            error: error instanceof Error ? error.message : 'Unknown error',
          });
        }
      }
      for (const refund of refunds) {
        try {
          await this.gateway.recoverRefund(refund);
          processed += 1;
        } catch (error) {
          failed += 1;
          logger.error('Failed to recover pending refund', {
            refundId: refund.id,
            error: error instanceof Error ? error.message : 'Unknown error',
          });
        }
      }

      await this.executions.complete({
        executionId: execution.id,
        workerId: this.workerId,
        completedAt: this.clock().toISOString(),
        result: {
          paymentCandidates: paymentIds.length,
          refundCandidates: refunds.length,
          processed,
          failed,
        },
      });
      return {
        claimed: true,
        paymentCandidates: paymentIds.length,
        refundCandidates: refunds.length,
        processed,
        failed,
      };
    } catch (error) {
      const failedAt = this.clock().toISOString();
      try {
        await this.executions.fail({
          executionId: execution.id,
          workerId: this.workerId,
          failureCode: 'PENDING_PAYMENT_RECOVERY_FAILED',
          failedAt,
        });
      } catch (failureError) {
        logger.error('Unable to persist pending payment recovery failure', {
          executionId: execution.id,
          error: failureError instanceof Error ? failureError.message : 'Unknown error',
        });
      }
      throw error;
    }
  }
}

export const pendingPaymentRecoveryWorker = new PendingPaymentRecoveryWorker(
  new SupabaseDurableJobExecutionRepository(),
  new SupabasePendingPaymentRecoveryGateway(),
);
