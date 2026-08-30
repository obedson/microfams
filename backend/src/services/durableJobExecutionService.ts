import { supabase } from '../utils/supabase.js';

export interface DurableJobExecution {
  id: string;
  attempt_count: number;
  max_attempts: number;
}

export interface DurableJobExecutionRepository {
  claim(input: {
    jobKey: string;
    scheduledFor: string;
    workerId: string;
    now: string;
    leaseSeconds: number;
    maxAttempts: number;
  }): Promise<DurableJobExecution | null>;
  complete(input: {
    executionId: string;
    workerId: string;
    completedAt: string;
    result: Record<string, unknown>;
  }): Promise<void>;
  fail(input: {
    executionId: string;
    workerId: string;
    failureCode: string;
    failedAt: string;
  }): Promise<void>;
}

const firstRow = <T>(value: T | T[] | null): T | null => {
  if (Array.isArray(value)) return value[0] ?? null;
  return value;
};

export class SupabaseDurableJobExecutionRepository
implements DurableJobExecutionRepository {
  async claim(input: {
    jobKey: string;
    scheduledFor: string;
    workerId: string;
    now: string;
    leaseSeconds: number;
    maxAttempts: number;
  }): Promise<DurableJobExecution | null> {
    const { data, error } = await supabase.rpc('claim_durable_job_execution', {
      p_job_key: input.jobKey,
      p_scheduled_for: input.scheduledFor,
      p_worker_id: input.workerId,
      p_now: input.now,
      p_lease_seconds: input.leaseSeconds,
      p_max_attempts: input.maxAttempts,
    });
    if (error) throw error;
    return firstRow(data as DurableJobExecution | DurableJobExecution[] | null);
  }

  async complete(input: {
    executionId: string;
    workerId: string;
    completedAt: string;
    result: Record<string, unknown>;
  }): Promise<void> {
    const { error } = await supabase.rpc('complete_durable_job_execution', {
      p_execution_id: input.executionId,
      p_worker_id: input.workerId,
      p_completed_at: input.completedAt,
      p_result_payload: input.result,
    });
    if (error) throw error;
  }

  async fail(input: {
    executionId: string;
    workerId: string;
    failureCode: string;
    failedAt: string;
  }): Promise<void> {
    const { error } = await supabase.rpc('fail_durable_job_execution', {
      p_execution_id: input.executionId,
      p_worker_id: input.workerId,
      p_failure_code: input.failureCode,
      p_failed_at: input.failedAt,
    });
    if (error) throw error;
  }
}
