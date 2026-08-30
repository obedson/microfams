import crypto from 'crypto';
import { payoutService } from '../domains/financial/payoutService.js';
import { DurableJobExecutionRepository, SupabaseDurableJobExecutionRepository } from './durableJobExecutionService.js';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'payouts.pending-reconciliation';
const HOUR_MS = 60 * 60 * 1000;
const scheduledHour = (date: Date): string => new Date(Math.floor(date.getTime() / HOUR_MS) * HOUR_MS).toISOString();
export interface PayoutReconciliationGateway { listPayoutIds(olderThan: string, limit: number): Promise<string[]>; reconcilePayout(id: string): Promise<void>; }
export interface PayoutReconciliationResult { claimed: boolean; candidates: number; processed: number; failed: number; }
export class SupabasePayoutReconciliationGateway implements PayoutReconciliationGateway {
  async listPayoutIds(olderThan: string, limit: number): Promise<string[]> {
    const { data, error } = await supabase.from('payouts').select('id').in('state', ['submitted', 'processing']).lt('updated_at', olderThan).order('updated_at', { ascending: true }).limit(limit);
    if (error) throw error;
    return (data ?? []).map((row: { id: string }) => row.id);
  }
  async reconcilePayout(id: string): Promise<void> { await payoutService.queryAndApply(id); }
}
export class PayoutReconciliationWorker {
  constructor(private readonly executions: DurableJobExecutionRepository, private readonly gateway: PayoutReconciliationGateway, private readonly clock: () => Date = () => new Date(), private readonly workerId = `payout-reconciliation-${crypto.randomUUID()}`) {}
  async runOnce(limit = 50): Promise<PayoutReconciliationResult> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new Error('Payout reconciliation limit is invalid');
    const startedAt = this.clock();
    const execution = await this.executions.claim({ jobKey: JOB_KEY, scheduledFor: scheduledHour(startedAt), workerId: this.workerId, now: startedAt.toISOString(), leaseSeconds: 1800, maxAttempts: 5 });
    if (!execution) return { claimed: false, candidates: 0, processed: 0, failed: 0 };
    try {
      const olderThan = new Date(startedAt.getTime() - 24 * HOUR_MS).toISOString();
      const ids = await this.gateway.listPayoutIds(olderThan, limit);
      let processed = 0; let failed = 0;
      for (const id of ids) { try { await this.gateway.reconcilePayout(id); processed += 1; } catch (error) { failed += 1; logger.error('Failed to reconcile pending payout', { payoutId: id, error: error instanceof Error ? error.message : 'Unknown error' }); } }
      await this.executions.complete({ executionId: execution.id, workerId: this.workerId, completedAt: this.clock().toISOString(), result: { candidates: ids.length, processed, failed } });
      return { claimed: true, candidates: ids.length, processed, failed };
    } catch (error) {
      try { await this.executions.fail({ executionId: execution.id, workerId: this.workerId, failureCode: 'PAYOUT_RECONCILIATION_FAILED', failedAt: this.clock().toISOString() }); } catch (failureError) { logger.error('Unable to persist payout reconciliation failure', { executionId: execution.id, error: failureError instanceof Error ? failureError.message : 'Unknown error' }); }
      throw error;
    }
  }
}
export const payoutReconciliationWorker = new PayoutReconciliationWorker(new SupabaseDurableJobExecutionRepository(), new SupabasePayoutReconciliationGateway());
