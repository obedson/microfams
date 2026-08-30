-- Prevent overlapping schedule slots for the same durable platform job.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION claim_durable_job_execution(
  p_job_key TEXT,
  p_scheduled_for TIMESTAMPTZ,
  p_worker_id TEXT,
  p_now TIMESTAMPTZ,
  p_lease_seconds INTEGER DEFAULT 900,
  p_max_attempts INTEGER DEFAULT 5
) RETURNS durable_job_executions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_execution durable_job_executions;
  v_previous TEXT;
BEGIN
  IF p_job_key !~ '^[a-z][a-z0-9_.-]{2,95}$'
    OR length(COALESCE(p_worker_id, '')) NOT BETWEEN 8 AND 160
    OR p_scheduled_for IS NULL OR p_now IS NULL OR p_scheduled_for > p_now
    OR p_lease_seconds NOT BETWEEN 30 AND 3600
    OR p_max_attempts NOT BETWEEN 1 AND 20
  THEN
    RAISE EXCEPTION 'DURABLE_JOB_CLAIM_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_job_key, 0));
  IF EXISTS (
    SELECT 1
    FROM durable_job_executions AS active
    WHERE active.job_key = p_job_key
      AND active.state = 'leased'
      AND active.lease_expires_at > p_now
  ) THEN
    RETURN NULL;
  END IF;

  v_previous := current_setting('microfams.durable_job_engine', TRUE);
  PERFORM set_config('microfams.durable_job_engine', 'on', TRUE);

  INSERT INTO durable_job_executions(
    job_key, scheduled_for, next_attempt_at, max_attempts
  ) VALUES (
    p_job_key, p_scheduled_for, p_scheduled_for, p_max_attempts
  )
  ON CONFLICT (job_key, scheduled_for) DO NOTHING;

  UPDATE durable_job_executions AS execution SET
    state = 'leased',
    attempt_count = execution.attempt_count + 1,
    lease_owner = p_worker_id,
    lease_expires_at = p_now + make_interval(secs => p_lease_seconds),
    failure_code = NULL,
    started_at = COALESCE(execution.started_at, p_now),
    updated_at = p_now
  WHERE execution.job_key = p_job_key
    AND execution.scheduled_for = p_scheduled_for
    AND execution.attempt_count < execution.max_attempts
    AND NOT EXISTS (
      SELECT 1
      FROM durable_job_executions AS active
      WHERE active.job_key = p_job_key
        AND active.state = 'leased'
        AND active.lease_expires_at > p_now
        AND active.id <> execution.id
    )
    AND (
      (execution.state IN ('queued', 'retry')
        AND execution.next_attempt_at <= p_now)
      OR (execution.state = 'leased' AND execution.lease_expires_at <= p_now)
    )
  RETURNING execution.* INTO v_execution;

  PERFORM set_config(
    'microfams.durable_job_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_execution;
END;
$$;

REVOKE ALL ON FUNCTION claim_durable_job_execution(
  TEXT, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_durable_job_execution(
  TEXT, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) TO service_role;
