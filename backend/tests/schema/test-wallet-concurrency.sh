#!/usr/bin/env bash
set -euo pipefail

container="${1:?schema container name is required}"
actor_id="00000000-0000-4000-8000-000000000102"
wallet_id="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT id FROM user_wallets WHERE organization_id = '00000000-0000-4000-8000-000000000101' AND user_id = '$actor_id'")"

if [[ -z "$wallet_id" ]]; then
  echo "concurrency wallet fixture is missing" >&2
  exit 1
fi

output_a="$(mktemp)"
output_b="$(mktemp)"
cleanup() { rm -f "$output_a" "$output_b"; }
trap cleanup EXIT

reserve() {
  local suffix="$1"
  docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
    --set ON_ERROR_STOP=1 --command "BEGIN; SELECT reserve_wallet_funds(
      '$wallet_id', 1500, 'concurrent-reservation-$suffix', 'concurrent-key-$suffix',
      '00000000-0000-4000-8000-00000000801$suffix', '$actor_id', NOW() + INTERVAL '10 minutes'
    ); SELECT pg_sleep(1); COMMIT;"
}

reserve 1 >"$output_a" 2>&1 &
pid_a=$!
reserve 2 >"$output_b" 2>&1 &
pid_b=$!

set +e
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

successes=0
if [[ "$status_a" -eq 0 ]]; then successes=$((successes + 1)); fi
if [[ "$status_b" -eq 0 ]]; then successes=$((successes + 1)); fi
if [[ "$successes" -ne 1 ]]; then
  echo "expected exactly one concurrent reservation to succeed" >&2
  cat "$output_a" "$output_b" >&2
  exit 1
fi

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --set ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  wallet_id UUID;
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  winner fund_reservations;
  summary JSONB;
BEGIN
  SELECT id INTO wallet_id FROM user_wallets
  WHERE organization_id = '00000000-0000-4000-8000-000000000101'
    AND user_id = actor_id;
  IF (SELECT count(*) FROM fund_reservations
      WHERE idempotency_key IN ('concurrent-key-1', 'concurrent-key-2')) <> 1 THEN
    RAISE EXCEPTION 'concurrent reservations created an unexpected row count';
  END IF;
  SELECT * INTO winner FROM fund_reservations
  WHERE idempotency_key IN ('concurrent-key-1', 'concurrent-key-2');
  summary := wallet_balance_summary(wallet_id);
  IF winner.state <> 'active'
    OR (summary->>'pendingDebitsMinor')::BIGINT <> 1500
    OR (summary->>'availableBalanceMinor')::BIGINT <> 800 THEN
    RAISE EXCEPTION 'concurrent reservation did not preserve available balance: %', summary;
  END IF;
  PERFORM release_wallet_reservation(winner.id, actor_id);
  summary := wallet_balance_summary(wallet_id);
  IF (summary->>'pendingDebitsMinor')::BIGINT <> 0
    OR (summary->>'availableBalanceMinor')::BIGINT <> 2300 THEN
    RAISE EXCEPTION 'concurrent reservation cleanup did not restore availability: %', summary;
  END IF;
END $$;
SQL
