#!/usr/bin/env bash
set -euo pipefail

container="${1:?schema container name is required}"
organization_id="00000000-0000-4000-8000-000000000101"
approver_id="00000000-0000-4000-8000-000000000101"
batch_id="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
  --tuples-only --no-align --command "SELECT id FROM savings_accrual_batches
    WHERE organization_id = '$organization_id'
      AND creation_idempotency_key = 'sav03-concurrency-calculate-001'")"

if [[ -z "$batch_id" ]]; then
  echo "savings accrual concurrency fixture is missing" >&2
  exit 1
fi

output_a="$(mktemp)"
output_b="$(mktemp)"
cleanup() { rm -f "$output_a" "$output_b"; }
trap cleanup EXIT

approve() {
  docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
    --set ON_ERROR_STOP=1 --command "BEGIN; SELECT approve_savings_accrual_batch(
      '$organization_id', '$approver_id', '$batch_id', 'sav03-concurrent-approve-001',
      '00000000-0000-4000-8000-000000000910', NOW()
    ); SELECT pg_sleep(1); COMMIT;"
}

approve >"$output_a" 2>&1 &
pid_a=$!
approve >"$output_b" 2>&1 &
pid_b=$!

set +e
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ "$status_a" -ne 0 || "$status_b" -ne 0 ]]; then
  echo "concurrent idempotent savings accrual approvals did not both succeed" >&2
  cat "$output_a" "$output_b" >&2
  exit 1
fi

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --set ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  target_batch savings_accrual_batches;
BEGIN
  SELECT * INTO target_batch FROM savings_accrual_batches
  WHERE organization_id='00000000-0000-4000-8000-000000000101'
    AND creation_idempotency_key='sav03-concurrency-calculate-001';
  IF target_batch.state<>'posted' OR target_batch.journal_entry_id IS NULL THEN
    RAISE EXCEPTION 'concurrent approval did not post the batch exactly once';
  END IF;
  IF (SELECT count(*) FROM savings_accrual_events
      WHERE batch_id=target_batch.id AND action='approved')<>1 THEN
    RAISE EXCEPTION 'concurrent approval created duplicate approval events';
  END IF;
  IF (SELECT count(*) FROM journal_entries
      WHERE organization_id=target_batch.organization_id
        AND source_domain='savings.accrual' AND source_record_id=target_batch.id::TEXT)<>1 THEN
    RAISE EXCEPTION 'concurrent approval created duplicate journals';
  END IF;
  IF (SELECT count(*) FROM journal_lines WHERE journal_entry_id=target_batch.journal_entry_id)<>2
    OR EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=target_batch.journal_entry_id
      GROUP BY journal_entry_id
      HAVING sum(CASE WHEN side='debit' THEN amount_minor ELSE -amount_minor END)<>0)
  THEN RAISE EXCEPTION 'concurrent approval journal is not balanced'; END IF;
END $$;
SQL
