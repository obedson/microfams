#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
container="microfams-schema-$RANDOM-$RANDOM"
port="${MICROFAMS_SCHEMA_TEST_PORT:-55432}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_postgres() {
  local stable_checks=0
  for _ in $(seq 1 60); do
    if docker exec "$container" psql --username postgres --dbname microfams \
      --no-psqlrc --tuples-only --command 'SELECT 1' >/dev/null 2>&1; then
      stable_checks=$((stable_checks + 1))
      if [[ "$stable_checks" -ge 3 ]]; then return 0; fi
    else
      stable_checks=0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become stably ready" >&2
  docker logs "$container" >&2 || true
  return 1
}

docker run --detach --name "$container" \
  --publish "127.0.0.1:${port}:5432" \
  --env POSTGRES_PASSWORD=postgres \
  --env POSTGRES_DB=microfams \
  postgres:16-alpine >/dev/null

wait_for_postgres

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-schema-bootstrap.sql" >/dev/null

while IFS= read -r migration || [[ -n "$migration" ]]; do
  [[ -z "$migration" || "$migration" == \#* ]] && continue
  echo "applying $migration"
  docker exec --interactive "$container" psql --username postgres --dbname microfams \
    --set ON_ERROR_STOP=1 < "$repo_root/backend/migrations/$migration" >/dev/null
done < "$repo_root/backend/migrations/schema-manifest.txt"

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY[
      'users','properties','bookings','groups','group_members','courses','user_progress',
      'marketplace_products','orders','user_wallets','wallet_transactions','organizations',
      'feature_flags','financial_accounts','journal_entries','journal_lines',
      'wallet_ledger_migration_runs','wallet_ledger_cutovers','wallet_ledger_migration_items','fund_reservations',
      'payouts','payout_attempts','provider_events','reconciliation_runs','reconciliation_items','reconciliation_exceptions'
    ]) AS required(name)
    WHERE to_regclass('public.' || required.name) IS NULL
  ) THEN
    RAISE EXCEPTION 'one or more required tables are missing';
  END IF;
END $$;

DO $$
DECLARE
  owner_id UUID;
  recipient_id UUID;
  recipient_wallet_id UUID;
  test_group_id UUID;
  request_id UUID;
  credit_transaction_id UUID;
  property_id UUID;
  state_key INTEGER;
  lga_key INTEGER;
  result JSON;
  transfer_result JSONB;
  actual_amount NUMERIC;
BEGIN
  INSERT INTO users (id, email, password, name, role)
  VALUES ('00000000-0000-4000-8000-000000000101', 'schema-owner@example.test', 'not-a-real-password', 'Schema Owner', 'owner')
  RETURNING id INTO owner_id;

  SELECT id INTO state_key FROM states ORDER BY id LIMIT 1;
  SELECT id INTO lga_key FROM lgas WHERE state_id = state_key ORDER BY id LIMIT 1;

  SELECT create_group_with_creator(
    'Schema Test Group', 'Clean install contract', 'mixed', owner_id, owner_id,
    state_key, lga_key, 1000, 50, 'schema-test-payment', 1000
  ) INTO result;

  IF result->>'group_id' IS NULL THEN
    RAISE EXCEPTION 'group creation RPC returned no group id';
  END IF;

  test_group_id := (result->>'group_id')::UUID;
  credit_transaction_id := atomic_group_credit(test_group_id, 2500, 'schema-group-credit');

  IF NOT EXISTS (
    SELECT 1 FROM wallet_transactions
    WHERE id = credit_transaction_id
      AND group_id = test_group_id
      AND wallet_id IS NULL
      AND direction = 'CREDIT'
      AND amount = 2500
  ) THEN
    RAISE EXCEPTION 'group credit did not create its ledger transaction';
  END IF;

  SELECT group_fund_balance INTO actual_amount FROM groups WHERE id = test_group_id;
  IF actual_amount <> 2500 THEN
    RAISE EXCEPTION 'group credit balance mismatch: %', actual_amount;
  END IF;

  INSERT INTO users (id, email, password, name, role)
  VALUES ('00000000-0000-4000-8000-000000000102', 'schema-recipient@example.test', 'not-a-real-password', 'Schema Recipient', 'farmer')
  RETURNING id INTO recipient_id;

  INSERT INTO users (id, email, password, name, role)
  VALUES ('00000000-0000-4000-8000-000000000103', 'schema-outsider@example.test', 'not-a-real-password', 'Schema Outsider', 'farmer');

  INSERT INTO properties (
    owner_id, organization_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to
  ) VALUES (
    owner_id, owner_id, 'Tenant A Farm', 'Tenant isolation fixture', 'poultry', 'empty_land',
    100, 'm2', 'Abuja', 'AMAC', 10000, CURRENT_DATE, CURRENT_DATE + 90
  ) RETURNING id INTO property_id;

  INSERT INTO bookings (
    property_id, farmer_id, organization_id, start_date, end_date, total_amount,
    status, payment_status
  ) VALUES (
    property_id, recipient_id, recipient_id, CURRENT_DATE + 1, CURRENT_DATE + 31,
    10000, 'pending_payment', 'pending'
  );

  INSERT INTO farm_records (
    farmer_id, organization_id, property_id, livestock_type, livestock_count,
    feed_consumption, mortality_count, expenses, expense_category, record_date
  ) VALUES (
    owner_id, owner_id, property_id, 'poultry', 50, 10, 1, 5000, 'feed', CURRENT_DATE
  );

  INSERT INTO user_wallets (user_id) VALUES (recipient_id) RETURNING id INTO recipient_wallet_id;
  INSERT INTO contribution_cycles(
    group_id, organization_id, cycle_month, cycle_year, expected_amount,
    outstanding_amount, deadline_date
  ) VALUES (
    test_group_id, owner_id, 1, 2099, 1000, 1000, DATE '2099-01-28'
  );
  INSERT INTO group_consensus_requests (
    group_id, requested_by, target_user_id, amount, status, request_type
  ) VALUES (
    test_group_id, owner_id, recipient_id, 1000, 'APPROVED', 'WITHDRAWAL'
  ) RETURNING id INTO request_id;

  transfer_result := atomic_group_transfer(
    test_group_id, recipient_wallet_id, 1000, 'schema-group-transfer', request_id
  );

  SELECT balance INTO actual_amount FROM user_wallets WHERE id = recipient_wallet_id;
  IF actual_amount <> 1000 THEN
    RAISE EXCEPTION 'recipient wallet balance mismatch: %', actual_amount;
  END IF;

  SELECT group_fund_balance INTO actual_amount FROM groups WHERE id = test_group_id;
  IF actual_amount <> 1500 THEN
    RAISE EXCEPTION 'group transfer balance mismatch: %', actual_amount;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM group_consensus_requests WHERE id = request_id AND status = 'EXECUTED'
  ) THEN
    RAISE EXCEPTION 'group transfer did not execute its consensus request';
  END IF;
END $$;

GRANT SELECT ON properties, bookings, farm_records, groups, contribution_cycles,
  user_wallets, wallet_transactions, withdrawal_requests TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM properties) <> 1 THEN
    RAISE EXCEPTION 'provider organization cannot read its property';
  END IF;
  IF (SELECT count(*) FROM bookings) <> 1 THEN
    RAISE EXCEPTION 'provider organization cannot read its booking';
  END IF;
  IF (SELECT count(*) FROM farm_records) <> 1 THEN
    RAISE EXCEPTION 'farm organization cannot read its farm records';
  END IF;
  IF (SELECT count(*) FROM groups) <> 1 OR (SELECT count(*) FROM contribution_cycles) <> 1 THEN
    RAISE EXCEPTION 'group organization cannot read its group finance records';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM properties) <> 0 THEN
    RAISE EXCEPTION 'customer organization leaked provider property';
  END IF;
  IF (SELECT count(*) FROM bookings) <> 1 THEN
    RAISE EXCEPTION 'customer organization cannot read its cross-tenant booking';
  END IF;
  IF (SELECT count(*) FROM farm_records) <> 0 THEN
    RAISE EXCEPTION 'customer organization leaked provider farm records';
  END IF;
  IF (SELECT count(*) FROM groups) <> 0 OR (SELECT count(*) FROM contribution_cycles) <> 0 THEN
    RAISE EXCEPTION 'customer organization leaked group finance records';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM properties) <> 0
    OR (SELECT count(*) FROM bookings) <> 0
    OR (SELECT count(*) FROM farm_records) <> 0
    OR (SELECT count(*) FROM groups) <> 0
    OR (SELECT count(*) FROM contribution_cycles) <> 0 THEN
    RAISE EXCEPTION 'unrelated organization can read tenant data';
  END IF;
END $$;
RESET ROLE;
SQL

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-marketplace-tenancy.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-education-tenancy.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-financial-ledger.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-wallet-ledger-cutover-readiness.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-wallet-ledger-cutover-activation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-wallet-posting-engine.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-wallet-fund-reservations.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-payout-orchestration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-financial-rules.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-identity-verification.sql"

echo "clean schema verification passed"
