#!/usr/bin/env bash
set -euo pipefail

container="${1:?schema container name is required}"
organization_id="00000000-0000-4000-8000-000000000101"
approver_id="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
  --tuples-only --no-align --command "SELECT user_id FROM organization_memberships
    WHERE organization_id='$organization_id' AND role='finance_manager'
      AND permissions @> ARRAY['financial.savings.configure']::TEXT[]
    ORDER BY joined_at DESC LIMIT 1")"
withdrawal_id="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
  --tuples-only --no-align --command "SELECT id FROM savings_withdrawals
    WHERE organization_id='$organization_id'
      AND creation_idempotency_key='sav04-concurrency-request-001'")"

if [[ -z "$approver_id" || -z "$withdrawal_id" ]]; then
  echo "savings withdrawal concurrency fixture is missing" >&2
  exit 1
fi

wallet_before="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
  --tuples-only --no-align --command "SELECT wallet_account_balance_minor(destination_account_id)
    FROM savings_withdrawals WHERE id='$withdrawal_id'")"
output_a="$(mktemp)"
output_b="$(mktemp)"
cleanup() { rm -f "$output_a" "$output_b"; }
trap cleanup EXIT

approve() {
  docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
    --set ON_ERROR_STOP=1 --command "BEGIN; SELECT review_savings_withdrawal(
      '$organization_id', '$approver_id', '$withdrawal_id', 'approve', NULL,
      'sav04-concurrent-approve-001', '00000000-0000-4000-8000-000000000a21', NOW()
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
  echo "concurrent idempotent savings withdrawal approvals did not both succeed" >&2
  cat "$output_a" "$output_b" >&2
  exit 1
fi

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --set ON_ERROR_STOP=1 --set wallet_before="$wallet_before" <<'SQL'
DO $$
DECLARE target savings_withdrawals;
BEGIN
  SELECT * INTO target FROM savings_withdrawals
  WHERE organization_id='00000000-0000-4000-8000-000000000101'
    AND creation_idempotency_key='sav04-concurrency-request-001';
  IF target.state<>'settled' OR target.journal_entry_id IS NULL THEN
    RAISE EXCEPTION 'concurrent approval did not settle the withdrawal';
  END IF;
  IF (SELECT count(*) FROM savings_withdrawal_events WHERE withdrawal_id=target.id AND action='approved')<>1
    OR (SELECT count(*) FROM journal_entries WHERE organization_id=target.organization_id
      AND source_domain='savings.withdrawal' AND source_record_id=target.id::TEXT)<>1
  THEN RAISE EXCEPTION 'concurrent approval created duplicate evidence or journals'; END IF;
  IF EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=target.journal_entry_id GROUP BY journal_entry_id
      HAVING sum(CASE WHEN side='debit' THEN amount_minor ELSE -amount_minor END)<>0)
  THEN RAISE EXCEPTION 'concurrent approval journal is not balanced'; END IF;
END $$;
SQL

wallet_after="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
  --tuples-only --no-align --command "SELECT wallet_account_balance_minor(destination_account_id)
    FROM savings_withdrawals WHERE id='$withdrawal_id'")"
if [[ "$wallet_after" -ne $((wallet_before + 50000)) ]]; then
  echo "concurrent approval credited the member wallet more or less than once" >&2
  exit 1
fi
