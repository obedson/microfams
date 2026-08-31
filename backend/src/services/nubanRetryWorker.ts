import crypto from 'crypto';
import { DurableJobExecutionRepository, SupabaseDurableJobExecutionRepository } from './durableJobExecutionService.js';
import { walletService } from './walletService.js';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

const JOB_KEY = 'wallet.nuban-provisioning-retry';
const FIVE_MINUTES_MS = 5 * 60 * 1000;
const scheduledFiveMinutes = (date: Date): string => new Date(Math.floor(date.getTime() / FIVE_MINUTES_MS) * FIVE_MINUTES_MS).toISOString();
export interface PendingNuban { id: string; groupId: string; organizationId: string; groupName: string; retryCount: number; updatedAt: string; }
export interface NubanRetryGateway { listPending(limit: number): Promise<PendingNuban[]>; provision(item: PendingNuban): Promise<void>; markFailure(item: PendingNuban, at: string): Promise<void>; }
export interface NubanRetryResult { claimed: boolean; candidates: number; attempted: number; provisioned: number; failed: number; deferred: number; }
export class SupabaseNubanRetryGateway implements NubanRetryGateway {
  async listPending(limit: number): Promise<PendingNuban[]> {
    const { data, error } = await supabase.from('group_virtual_accounts').select('id, group_id, organization_id, retry_count, updated_at, groups!inner(name)').eq('status', 'PENDING').lt('retry_count', 3).order('updated_at', { ascending: true }).limit(limit);
    if (error) throw error;
    return (data ?? []).map((row: any) => ({ id: row.id, groupId: row.group_id, organizationId: row.organization_id, groupName: row.groups.name, retryCount: row.retry_count, updatedAt: row.updated_at }));
  }
  async provision(item: PendingNuban): Promise<void> { await walletService.provisionGroupNuban(item.groupId, item.groupName); }
  async markFailure(item: PendingNuban, at: string): Promise<void> {
    const { error } = await supabase.from('group_virtual_accounts').update({ retry_count: item.retryCount + 1, updated_at: at }).eq('id', item.id).eq('organization_id', item.organizationId).eq('status', 'PENDING').eq('retry_count', item.retryCount);
    if (error) throw error;
  }
}
export class NubanRetryWorker {
  constructor(private readonly executions: DurableJobExecutionRepository, private readonly gateway: NubanRetryGateway, private readonly clock: () => Date = () => new Date(), private readonly workerId = `nuban-retry-${crypto.randomUUID()}`) {}
  async runOnce(limit = 50): Promise<NubanRetryResult> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new Error('NUBAN retry limit is invalid');
    const startedAt = this.clock();
    const execution = await this.executions.claim({ jobKey: JOB_KEY, scheduledFor: scheduledFiveMinutes(startedAt), workerId: this.workerId, now: startedAt.toISOString(), leaseSeconds: 240, maxAttempts: 5 });
    if (!execution) return { claimed: false, candidates: 0, attempted: 0, provisioned: 0, failed: 0, deferred: 0 };
    try {
      const items = await this.gateway.listPending(limit); let attempted = 0; let provisioned = 0; let failed = 0; let deferred = 0;
      for (const item of items) {
        const delayMs = 2 ** item.retryCount * 60 * 1000;
        if (startedAt.getTime() - new Date(item.updatedAt).getTime() < delayMs) { deferred += 1; continue; }
        attempted += 1;
        try { await this.gateway.provision(item); provisioned += 1; }
        catch (error) { failed += 1; await this.gateway.markFailure(item, this.clock().toISOString()); logger.error('NUBAN retry failed', { groupId: item.groupId, error: error instanceof Error ? error.message : 'Unknown error' }); }
      }
      await this.executions.complete({ executionId: execution.id, workerId: this.workerId, completedAt: this.clock().toISOString(), result: { candidates: items.length, attempted, provisioned, failed, deferred } });
      return { claimed: true, candidates: items.length, attempted, provisioned, failed, deferred };
    } catch (error) {
      try { await this.executions.fail({ executionId: execution.id, workerId: this.workerId, failureCode: 'NUBAN_RETRY_FAILED', failedAt: this.clock().toISOString() }); } catch (failureError) { logger.error('Unable to persist NUBAN retry failure', { executionId: execution.id, error: failureError instanceof Error ? failureError.message : 'Unknown error' }); }
      throw error;
    }
  }
}
export const nubanRetryWorker = new NubanRetryWorker(new SupabaseDurableJobExecutionRepository(), new SupabaseNubanRetryGateway());
