#!/usr/bin/env bash
set -euo pipefail

container="${1:?schema container name is required}"
output_a="$(mktemp)"
output_b="$(mktemp)"
cleanup() { rm -f "$output_a" "$output_b"; }
trap cleanup EXIT

reserve() {
  local suffix="$1"
  docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc \
    --set ON_ERROR_STOP=1 --command "BEGIN; SELECT create_booking_reservation(
      '00000000-0000-4000-8000-000000009901',
      '00000000-0000-4000-8000-000000009911',
      '00000000-0000-4000-8000-000000009921',
      CURRENT_DATE + 100, CURRENT_DATE + 130, NULL,
      'booking-concurrency-$suffix',
      '00000000-0000-4000-8000-00000000994$suffix'
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
[[ "$status_a" -eq 0 ]] && successes=$((successes + 1))
[[ "$status_b" -eq 0 ]] && successes=$((successes + 1))
if [[ "$successes" -ne 1 ]]; then
  echo "expected exactly one concurrent booking reservation to succeed" >&2
  cat "$output_a" "$output_b" >&2
  exit 1
fi

count="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align \
  --command "SELECT count(*) FROM booking_reservation_holds WHERE idempotency_key IN ('booking-concurrency-1','booking-concurrency-2')")"
if [[ "$count" != "1" ]]; then
  echo "concurrent booking reservation row count was $count" >&2
  exit 1
fi
