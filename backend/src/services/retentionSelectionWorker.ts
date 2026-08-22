import crypto from 'node:crypto';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export interface RetentionSelectionRun {
  id: string;
  requested_by: string;
  idempotency_key: string;
  request_hash: string;
}

export interface RetentionSelectionRepository {
  listPlanned(limit: number): Promise<RetentionSelectionRun[]>;
  select(run: RetentionSelectionRun): Promise<unknown>;
}

export class SupabaseRetentionSelectionRepository implements RetentionSelectionRepository {
  async listPlanned(limit: number): Promise<RetentionSelectionRun[]> {
    const { data, error } = await supabase
      .from('data_retention_runs')
      .select('id, requested_by, idempotency_key, request_hash')
      .eq('mode', 'dry_run')
      .eq('status', 'planned')
      .order('created_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    return (data ?? []) as RetentionSelectionRun[];
  }

  async select(run: RetentionSelectionRun): Promise<unknown> {
    const requestHash = crypto.createHash('sha256')
      .update(`retention-selection:${run.id}:${run.request_hash}`)
      .digest('hex');
    const { data, error } = await supabase.rpc('select_retention_dry_run_items', {
      p_actor: run.requested_by,
      p_run: run.id,
      p_idempotency_key: `${run.idempotency_key}:select-items`,
      p_request_hash: requestHash,
    });
    if (error) throw error;
    return data;
  }
}

export class RetentionSelectionWorker {
  constructor(private readonly repository: RetentionSelectionRepository) {}

  async runOnce(limit = 20): Promise<{ scanned: number; completed: number; failed: number }> {
    const runs = await this.repository.listPlanned(limit);
    let completed = 0;
    let failed = 0;
    for (const run of runs) {
      try {
        await this.repository.select(run);
        completed += 1;
      } catch (error) {
        failed += 1;
        logger.error('Retention dry-run selection failed', { runId: run.id, error });
      }
    }
    return { scanned: runs.length, completed, failed };
  }
}

export const retentionSelectionWorker = new RetentionSelectionWorker(
  new SupabaseRetentionSelectionRepository(),
);
