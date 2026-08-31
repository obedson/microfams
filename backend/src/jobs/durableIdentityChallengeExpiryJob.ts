import crypto from 'node:crypto';
import { identityChallengeExpiryWorker } from '../services/identityChallengeExpiryWorker.js';
import {
  DurableJobExecutionRepository,
  SupabaseDurableJobExecutionRepository,
} from '../services/durableJobExecutionService.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'identity.challenge-expiry';
const scheduledMinute = (date: Date): string =>
  new Date(Math.floor(date.getTime() / 60000) * 60000).toISOString();

export interface IdentityChallengeExpiryRunner {
  runOnce(limit?: number): Promise<{ expired: number }>;
}

export interface DurableIdentityChallengeExpiryResult {
  claimed: boolean;
  expired: number;
}

export class DurableIdentityChallengeExpiryJob {
  constructor(
    private readonly executions: DurableJobExecutionRepository,
    private readonly runner: IdentityChallengeExpiryRunner,
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `identity-expiry-${crypto.randomUUID()}`,
  ) {}

  async runOnce(limit = 100): Promise<DurableIdentityChallengeExpiryResult> {
    const startedAt = this.clock();
    const execution = await this.executions.claim({
      jobKey: JOB_KEY,
      scheduledFor: scheduledMinute(startedAt),
      workerId: this.workerId,
      now: startedAt.toISOString(),
      leaseSeconds: 55,
      maxAttempts: 5,
    });
    if (!execution) return { claimed: false, expired: 0 };

    try {
      const result = await this.runner.runOnce(limit);
      await this.executions.complete({
        executionId: execution.id,
        workerId: this.workerId,
        completedAt: this.clock().toISOString(),
        result,
      });
      return { claimed: true, ...result };
    } catch (error) {
      try {
        await this.executions.fail({
          executionId: execution.id,
          workerId: this.workerId,
          failureCode: 'IDENTITY_CHALLENGE_EXPIRY_JOB_FAILED',
          failedAt: this.clock().toISOString(),
        });
      } catch {
        logger.error('Unable to persist identity challenge expiry failure', {
          executionId: execution.id,
          failureCode: 'IDENTITY_CHALLENGE_EXPIRY_EVIDENCE_FAILED',
        });
      }
      throw error;
    }
  }
}

export const durableIdentityChallengeExpiryJob = new DurableIdentityChallengeExpiryJob(
  new SupabaseDurableJobExecutionRepository(),
  identityChallengeExpiryWorker,
);
