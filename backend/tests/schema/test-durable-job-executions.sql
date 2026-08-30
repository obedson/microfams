BEGIN;

DO $$
DECLARE
  v_now TIMESTAMPTZ := TIMESTAMPTZ '2026-08-30 10:00:00+00';
  v_execution durable_job_executions;
  v_duplicate durable_job_executions;
  v_recovered durable_job_executions;
BEGIN
  IF has_table_privilege(
    'authenticated', 'durable_job_executions', 'SELECT'
  ) OR has_table_privilege(
    'authenticated', 'durable_job_executions', 'INSERT'
  ) OR has_table_privilege(
    'authenticated', 'durable_job_executions', 'UPDATE'
  ) OR has_table_privilege(
    'authenticated', 'durable_job_executions', 'DELETE'
  ) THEN
    RAISE EXCEPTION 'tenant clients can inspect or mutate durable job executions';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'claim_durable_job_execution(text,timestamp with time zone,text,timestamp with time zone,integer,integer)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'complete_durable_job_execution(uuid,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'fail_durable_job_execution(uuid,text,text,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'tenant clients can operate durable platform jobs';
  END IF;

  v_execution := claim_durable_job_execution(
    'payments.timeout-cancellation',
    v_now,
    'schema-worker-one',
    v_now,
    300,
    3
  );
  IF v_execution.id IS NULL OR v_execution.state <> 'leased'
    OR v_execution.attempt_count <> 1
    OR v_execution.lease_owner <> 'schema-worker-one'
    OR v_execution.lease_expires_at <> v_now + INTERVAL '300 seconds'
  THEN
    RAISE EXCEPTION 'durable job lease evidence is incomplete: %', v_execution;
  END IF;

  v_duplicate := claim_durable_job_execution(
    'payments.timeout-cancellation',
    v_now,
    'schema-worker-two',
    v_now + INTERVAL '1 second',
    300,
    3
  );
  IF v_duplicate.id IS NOT NULL THEN
    RAISE EXCEPTION 'concurrent worker claimed an active durable job lease';
  END IF;

  v_execution := fail_durable_job_execution(
    v_execution.id,
    'schema-worker-one',
    'SYNTHETIC_FAILURE',
    v_now + INTERVAL '2 seconds'
  );
  IF v_execution.state <> 'retry'
    OR v_execution.next_attempt_at <> v_now + INTERVAL '32 seconds'
    OR v_execution.failure_code <> 'SYNTHETIC_FAILURE'
  THEN
    RAISE EXCEPTION 'durable job retry evidence is incomplete: %', v_execution;
  END IF;

  v_execution := claim_durable_job_execution(
    'payments.timeout-cancellation',
    v_now,
    'schema-worker-two',
    v_now + INTERVAL '33 seconds',
    300,
    3
  );
  v_execution := complete_durable_job_execution(
    v_execution.id,
    'schema-worker-two',
    v_now + INTERVAL '34 seconds',
    jsonb_build_object('processed', 4, 'cancelled', 3)
  );
  IF v_execution.state <> 'succeeded'
    OR v_execution.attempt_count <> 2
    OR v_execution.result_payload->>'cancelled' <> '3'
    OR v_execution.completed_at <> v_now + INTERVAL '34 seconds'
  THEN
    RAISE EXCEPTION 'durable job completion evidence is incomplete: %', v_execution;
  END IF;

  v_recovered := claim_durable_job_execution(
    'payments.timeout-cancellation',
    v_now - INTERVAL '1 hour',
    'schema-worker-one',
    v_now,
    300,
    3
  );
  v_recovered := claim_durable_job_execution(
    'payments.timeout-cancellation',
    v_now - INTERVAL '1 hour',
    'schema-worker-two',
    v_now + INTERVAL '301 seconds',
    300,
    3
  );
  IF v_recovered.id IS NULL OR v_recovered.lease_owner <> 'schema-worker-two'
    OR v_recovered.attempt_count <> 2
  THEN
    RAISE EXCEPTION 'expired durable job lease was not recoverable: %', v_recovered;
  END IF;
END $$;

ROLLBACK;
SELECT 'durable job execution schema tests passed' AS result;
