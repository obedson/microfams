import crypto from 'crypto';
import { savingsStandingOrderWorker } from '../domains/financial/savingsStandingOrderWorker.js';
import { DurableJobExecutionRepository, SupabaseDurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'savings.standing-order-servicing';
const scheduledMinute = (date: Date): string => new Date(Math.floor(date.getTime() / 60000) * 60000).toISOString();
export interface SavingsStandingOrderRunner { runOnce(limit?: number): Promise<{ due: number; serviced: number; skipped: number; errors: number }>; }
export interface DurableSavingsResult { claimed: boolean; due: number; serviced: number; skipped: number; errors: number; }
export class DurableSavingsStandingOrderJob {
  constructor(private readonly executions: DurableJobExecutionRepository, private readonly runner: SavingsStandingOrderRunner, private readonly clock: () => Date = () => new Date(), private readonly workerId = `savings-durable-${crypto.randomUUID()}`) {}
  async runOnce(limit = 50): Promise<DurableSavingsResult> {
    const startedAt = this.clock();
    const execution = await this.executions.claim({ jobKey: JOB_KEY, scheduledFor: scheduledMinute(startedAt), workerId: this.workerId, now: startedAt.toISOString(), leaseSeconds: 55, maxAttempts: 5 });
    if (!execution) return { claimed: false, due: 0, serviced: 0, skipped: 0, errors: 0 };
    try {
      const result = await this.runner.runOnce(limit);
      await this.executions.complete({ executionId: execution.id, workerId: this.workerId, completedAt: this.clock().toISOString(), result });
      return { claimed: true, ...result };
    } catch (error) {
      try { await this.executions.fail({ executionId: execution.id, workerId: this.workerId, failureCode: 'SAVINGS_STANDING_ORDER_JOB_FAILED', failedAt: this.clock().toISOString() }); } catch (failureError) { logger.error('Unable to persist savings job failure', { executionId: execution.id, error: failureError instanceof Error ? failureError.message : 'Unknown error' }); }
      throw error;
    }
  }
}
export const durableSavingsStandingOrderJob = new DurableSavingsStandingOrderJob(new SupabaseDurableJobExecutionRepository(), savingsStandingOrderWorker);
