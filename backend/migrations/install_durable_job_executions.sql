-- WP-P1-005: durable, recoverable execution leases for scheduled platform jobs.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS durable_job_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_key TEXT NOT NULL CHECK (job_key ~ '^[a-z][a-z0-9_.-]{2,95}$'),
  scheduled_for TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'leased', 'retry', 'succeeded', 'dead_letter')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 20),
  max_attempts INTEGER NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 20),
  next_attempt_at TIMESTAMPTZ NOT NULL,
  lease_owner TEXT,
  lease_expires_at TIMESTAMPTZ,
  result_payload JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(result_payload) = 'object'),
  failure_code TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (job_key, scheduled_for),
  CHECK (
    (state = 'leased' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR (state <> 'leased' AND lease_owner IS NULL AND lease_expires_at IS NULL)
  ),
  CHECK ((state = 'succeeded') = (completed_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_durable_job_executions_claim
  ON durable_job_executions(state, next_attempt_at, scheduled_for, id)
  WHERE state IN ('queued', 'retry', 'leased');

CREATE OR REPLACE FUNCTION protect_durable_job_execution() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.durable_job_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'DURABLE_JOB_ENGINE_REQUIRED';
END;
$$;

DROP TRIGGER IF EXISTS durable_job_executions_engine_only
  ON durable_job_executions;
CREATE TRIGGER durable_job_executions_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON durable_job_executions
  FOR EACH ROW EXECUTE FUNCTION protect_durable_job_execution();

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

CREATE OR REPLACE FUNCTION complete_durable_job_execution(
  p_execution_id UUID,
  p_worker_id TEXT,
  p_completed_at TIMESTAMPTZ,
  p_result_payload JSONB DEFAULT '{}'::JSONB
) RETURNS durable_job_executions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_execution durable_job_executions;
  v_previous TEXT;
BEGIN
  IF p_execution_id IS NULL OR p_completed_at IS NULL
    OR jsonb_typeof(COALESCE(p_result_payload, '{}'::JSONB)) <> 'object'
  THEN
    RAISE EXCEPTION 'DURABLE_JOB_COMPLETION_INVALID';
  END IF;

  SELECT * INTO v_execution
  FROM durable_job_executions
  WHERE id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND OR v_execution.state <> 'leased'
    OR v_execution.lease_owner <> p_worker_id
  THEN
    RAISE EXCEPTION 'DURABLE_JOB_LEASE_INVALID';
  END IF;

  v_previous := current_setting('microfams.durable_job_engine', TRUE);
  PERFORM set_config('microfams.durable_job_engine', 'on', TRUE);
  UPDATE durable_job_executions SET
    state = 'succeeded',
    result_payload = COALESCE(p_result_payload, '{}'::JSONB),
    failure_code = NULL,
    lease_owner = NULL,
    lease_expires_at = NULL,
    completed_at = p_completed_at,
    updated_at = p_completed_at
  WHERE id = p_execution_id
  RETURNING * INTO v_execution;
  PERFORM set_config(
    'microfams.durable_job_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_execution;
END;
$$;

CREATE OR REPLACE FUNCTION fail_durable_job_execution(
  p_execution_id UUID,
  p_worker_id TEXT,
  p_failure_code TEXT,
  p_failed_at TIMESTAMPTZ
) RETURNS durable_job_executions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_execution durable_job_executions;
  v_previous TEXT;
BEGIN
  IF p_execution_id IS NULL OR p_failed_at IS NULL
    OR p_failure_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
  THEN
    RAISE EXCEPTION 'DURABLE_JOB_FAILURE_INVALID';
  END IF;

  SELECT * INTO v_execution
  FROM durable_job_executions
  WHERE id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND OR v_execution.state <> 'leased'
    OR v_execution.lease_owner <> p_worker_id
  THEN
    RAISE EXCEPTION 'DURABLE_JOB_LEASE_INVALID';
  END IF;

  v_previous := current_setting('microfams.durable_job_engine', TRUE);
  PERFORM set_config('microfams.durable_job_engine', 'on', TRUE);
  UPDATE durable_job_executions SET
    state = CASE
      WHEN attempt_count >= max_attempts THEN 'dead_letter'
      ELSE 'retry'
    END,
    next_attempt_at = p_failed_at + make_interval(
      secs => LEAST(
        3600,
        30 * power(2, LEAST(GREATEST(attempt_count - 1, 0), 7))::INTEGER
      )
    ),
    failure_code = p_failure_code,
    lease_owner = NULL,
    lease_expires_at = NULL,
    updated_at = p_failed_at
  WHERE id = p_execution_id
  RETURNING * INTO v_execution;
  PERFORM set_config(
    'microfams.durable_job_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_execution;
END;
$$;

ALTER TABLE durable_job_executions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON durable_job_executions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON durable_job_executions TO service_role;
REVOKE INSERT, UPDATE, DELETE ON durable_job_executions FROM service_role;

REVOKE ALL ON FUNCTION claim_durable_job_execution(
  TEXT, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_durable_job_execution(
  TEXT, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) TO service_role;
REVOKE ALL ON FUNCTION complete_durable_job_execution(
  UUID, TEXT, TIMESTAMPTZ, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_durable_job_execution(
  UUID, TEXT, TIMESTAMPTZ, JSONB
) TO service_role;
REVOKE ALL ON FUNCTION fail_durable_job_execution(
  UUID, TEXT, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION fail_durable_job_execution(
  UUID, TEXT, TEXT, TIMESTAMPTZ
) TO service_role;
