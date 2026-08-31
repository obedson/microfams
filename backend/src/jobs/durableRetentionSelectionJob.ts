import crypto from 'crypto';
import { retentionSelectionWorker } from '../services/retentionSelectionWorker.js';
import { DurableJobExecutionRepository, SupabaseDurableJobExecutionRepository } from '../services/durableJobExecutionService.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'retention.dry-run-selection';
const FIVE_MINUTES_MS = 5 * 60 * 1000;
const scheduledFiveMinutes = (date: Date): string => new Date(Math.floor(date.getTime() / FIVE_MINUTES_MS) * FIVE_MINUTES_MS).toISOString();
export interface RetentionSelectionRunner { runOnce(limit?: number): Promise<{ scanned: number; completed: number; failed: number }>; }
export interface DurableRetentionResult { claimed: boolean; scanned: number; completed: number; failed: number; }
export class DurableRetentionSelectionJob {
  constructor(private readonly executions: DurableJobExecutionRepository, private readonly runner: RetentionSelectionRunner, private readonly clock: () => Date = () => new Date(), private readonly workerId = `retention-durable-${crypto.randomUUID()}`) {}
  async runOnce(limit = 20): Promise<DurableRetentionResult> {
    const startedAt = this.clock();
    const execution = await this.executions.claim({ jobKey: JOB_KEY, scheduledFor: scheduledFiveMinutes(startedAt), workerId: this.workerId, now: startedAt.toISOString(), leaseSeconds: 240, maxAttempts: 5 });
    if (!execution) return { claimed: false, scanned: 0, completed: 0, failed: 0 };
    try {
      const result = await this.runner.runOnce(limit);
      await this.executions.complete({ executionId: execution.id, workerId: this.workerId, completedAt: this.clock().toISOString(), result });
      return { claimed: true, ...result };
    } catch (error) {
      try { await this.executions.fail({ executionId: execution.id, workerId: this.workerId, failureCode: 'RETENTION_SELECTION_JOB_FAILED', failedAt: this.clock().toISOString() }); } catch (failureError) { logger.error('Unable to persist retention selection failure', { executionId: execution.id, error: failureError instanceof Error ? failureError.message : 'Unknown error' }); }
      throw error;
    }
  }
}
export const durableRetentionSelectionJob = new DurableRetentionSelectionJob(new SupabaseDurableJobExecutionRepository(), retentionSelectionWorker);
