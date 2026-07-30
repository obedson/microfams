#!/usr/bin/env bash
set -euo pipefail

repo_root=/workspaces/microfams
container="microfams-upgrade-$RANDOM-$RANDOM"
cleanup() { docker rm --force "$container" >/dev/null 2>&1 || true; }
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

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo "SUPABASE_DB_URL is missing" >&2
  exit 1
fi

docker run --rm --env SUPABASE_DB_URL postgres:17-alpine \
  pg_dump "$SUPABASE_DB_URL" --schema-only --schema=public --no-owner --no-privileges \
  > /tmp/microfams-remote-public-schema.sql
sed -i '/^CREATE SCHEMA public;$/d' /tmp/microfams-remote-public-schema.sql

docker run --detach --name "$container" \
  --env POSTGRES_PASSWORD=postgres --env POSTGRES_DB=microfams \
  postgres:17-alpine >/dev/null
wait_for_postgres

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-schema-bootstrap.sql" >/dev/null
docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
  --command 'CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;' \
  >/dev/null
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 < /tmp/microfams-remote-public-schema.sql >/dev/null

# A current hosted schema may already contain the earlier tenant/financial chain.
# Replaying non-idempotent historical migrations over that state is unsafe, so
# exercise the full ownerless legacy upgrade only when tenant ownership is absent.
tenant_ownership_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align --command "SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bookings' AND column_name = 'organization_id'
  )")"

legacy_shape=false
migrations=()
if [[ "$tenant_ownership_present" == "f" ]]; then
  legacy_shape=true
  docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
    --command "INSERT INTO bookings(start_date, end_date, total_amount, status, payment_status) VALUES (CURRENT_DATE, CURRENT_DATE + 30, 1000, 'confirmed', 'paid');" \
    >/dev/null
  migrations=(
    create_organizations.sql repair_group_wallet_ledger.sql add_domain_tenant_ownership.sql
    add_marketplace_order_workflow.sql add_education_reporting_tenancy.sql add_atomic_group_creation.sql
    create_feature_flags.sql create_financial_ledger.sql prepare_wallet_ledger_cutover.sql
    activate_wallet_ledger_cutover.sql install_wallet_posting_engine.sql create_wallet_fund_reservations.sql
    create_payout_orchestration.sql create_payment_orchestration.sql create_financial_rules.sql
    create_identity_verification.sql create_organization_verification.sql create_platform_administration.sql
    create_trust_review_appeals.sql create_suspended_account_recovery.sql create_legal_hold_commands.sql create_retention_item_selection.sql install_payment_engine.sql install_payment_servicing.sql install_payment_settlement.sql
  )
else
  trust_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
    --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.trust_review_cases') IS NOT NULL")"
  if [[ "$trust_schema_present" == "f" ]]; then
    migrations=(create_trust_review_appeals.sql create_suspended_account_recovery.sql create_legal_hold_commands.sql create_retention_item_selection.sql)
  else
    recovery_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
      --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.suspended_account_recovery_tokens') IS NOT NULL")"
    if [[ "$recovery_schema_present" == "f" ]]; then migrations+=(create_suspended_account_recovery.sql); fi
    legal_hold_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
      --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.data_legal_hold_events') IS NOT NULL")"
    if [[ "$legal_hold_schema_present" == "f" ]]; then migrations+=(create_legal_hold_commands.sql); fi
    retention_selection_present="$(docker exec "$container" psql --username postgres --dbname microfams \
      --no-psqlrc --tuples-only --no-align --command "SELECT to_regprocedure('public.select_retention_dry_run_items(uuid,uuid,text,text)') IS NOT NULL")"
    if [[ "$retention_selection_present" == "f" ]]; then migrations+=(create_retention_item_selection.sql); fi
  fi
fi

booking_refund_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_cancellations') IS NOT NULL")"
if [[ "$booking_refund_schema_present" == "f" ]]; then
  migrations+=(install_booking_refund_orchestration.sql)
fi

booking_reservation_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure('public.create_booking_reservation(uuid,uuid,uuid,date,date,text,text,uuid)') IS NOT NULL")"
if [[ "$booking_reservation_schema_present" == "f" ]]; then migrations+=(install_atomic_booking_reservations.sql); fi

booking_lifecycle_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure('public.transition_booking_state(uuid,uuid,uuid,text,text,uuid)') IS NOT NULL")"
if [[ "$booking_lifecycle_schema_present" == "f" ]]; then migrations+=(install_booking_state_transitions.sql); fi
booking_settlement_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_settlement_contracts') IS NOT NULL")"
if [[ "$booking_settlement_schema_present" == "f" ]]; then migrations+=(install_booking_settlement_foundation.sql); fi
booking_settlement_eligibility_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_settlement_rules') IS NOT NULL
    AND to_regprocedure('public.release_booking_settlement(uuid,uuid,uuid,text,uuid)') IS NOT NULL")"
if [[ "$booking_settlement_eligibility_schema_present" == "f" ]]; then
  migrations+=(install_booking_settlement_eligibility_fees.sql)
fi

booking_dispute_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_disputes') IS NOT NULL
    AND to_regprocedure('public.open_booking_dispute(uuid,uuid,uuid,text,text,text,bigint,text,uuid)') IS NOT NULL")"
if [[ "$booking_dispute_schema_present" == "f" ]]; then
  migrations+=(install_booking_dispute_opening.sql)
fi

booking_dispute_resolution_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_dispute_resolution_proposals') IS NOT NULL
    AND to_regprocedure('public.decide_booking_dispute_resolution(uuid,uuid,boolean,text,text,uuid)') IS NOT NULL")"
if [[ "$booking_dispute_resolution_schema_present" == "f" ]]; then
  migrations+=(install_booking_dispute_resolution.sql)
fi

booking_supplier_payout_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_payout_beneficiaries') IS NOT NULL
    AND to_regprocedure('public.create_booking_supplier_payout(uuid,uuid,uuid,uuid,text,text,text,uuid)') IS NOT NULL")"
if [[ "$booking_supplier_payout_schema_present" == "f" ]]; then
  migrations+=(install_booking_supplier_payout.sql)
fi

booking_recovery_schema_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_recovery_cases') IS NOT NULL")"
if [[ "$booking_recovery_schema_present" == "f" ]]; then
  migrations+=(install_booking_reversal_recovery.sql)
fi

booking_recovery_servicing_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_recovery_actions') IS NOT NULL")"
if [[ "$booking_recovery_servicing_present" == "f" ]]; then
  migrations+=(install_booking_recovery_servicing.sql)
fi
booking_authorization_audit_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.booking_authorization_decisions') IS NOT NULL
    AND to_regprocedure('public.evaluate_booking_authorization(uuid,uuid,text,text,text,text,uuid,text)') IS NOT NULL")"
if [[ "$booking_authorization_audit_present" == "f" ]]; then
  migrations+=(install_booking_authorization_audit.sql)
fi


for migration in "${migrations[@]}"; do
  echo "dry-run applying $migration"
  docker exec --interactive "$container" psql --username postgres --dbname microfams \
    --set ON_ERROR_STOP=1 < "$repo_root/backend/migrations/$migration" >/dev/null
done

if $legacy_shape; then
  docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
    --command "DO \$\$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM bookings
        WHERE farmer_id IS NULL AND property_id IS NULL
          AND organization_id = '00000000-0000-4000-8000-000000000900'
          AND provider_organization_id = '00000000-0000-4000-8000-000000000900'
      ) THEN RAISE EXCEPTION 'ownerless booking was not quarantined'; END IF;
      IF EXISTS (
        SELECT 1 FROM organization_memberships
        WHERE organization_id = '00000000-0000-4000-8000-000000000900'
      ) THEN RAISE EXCEPTION 'quarantine organization must not have members'; END IF;
    END \$\$;" >/dev/null
fi

docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
  --command "DO \$\$ BEGIN
    IF to_regclass('public.trust_review_cases') IS NULL
      OR to_regprocedure('public.file_trust_appeal(uuid,uuid,text,text,text)') IS NULL
      OR to_regclass('public.suspended_account_recovery_tokens') IS NULL
      OR to_regprocedure('public.file_suspended_account_recovery_appeal(text,text,text,text)') IS NULL
      OR to_regclass('public.data_legal_hold_events') IS NULL
      OR to_regprocedure('public.place_data_legal_hold(uuid,uuid,text,text,text,text,text,text)') IS NULL
      OR to_regprocedure('public.select_retention_dry_run_items(uuid,uuid,text,text)') IS NULL
      OR to_regclass('public.booking_price_snapshots') IS NULL
      OR to_regprocedure('public.create_booking_reservation(uuid,uuid,uuid,date,date,text,text,uuid)') IS NULL
      OR to_regclass('public.booking_state_transitions') IS NULL
      OR to_regprocedure('public.transition_booking_state(uuid,uuid,uuid,text,text,uuid)') IS NULL
      OR to_regclass('public.booking_settlement_contracts') IS NULL
      OR to_regclass('public.booking_settlement_allocations') IS NULL
      OR to_regclass('public.booking_settlement_rules') IS NULL
      OR to_regclass('public.booking_fee_rules') IS NULL
      OR to_regprocedure('public.release_booking_settlement(uuid,uuid,uuid,text,uuid)') IS NULL
      OR to_regclass('public.booking_disputes') IS NULL
      OR to_regclass('public.booking_dispute_evidence') IS NULL
      OR to_regprocedure('public.open_booking_dispute(uuid,uuid,uuid,text,text,text,bigint,text,uuid)') IS NULL
      OR to_regclass('public.booking_dispute_resolution_proposals') IS NULL
      OR to_regclass('public.booking_dispute_response_rules') IS NULL
      OR to_regclass('public.booking_settlement_releases') IS NULL
      OR to_regprocedure('public.decide_booking_dispute_resolution(uuid,uuid,boolean,text,text,uuid)') IS NULL
      OR to_regprocedure('public.read_booking_dispute_resolution_case(uuid,uuid,uuid)') IS NULL
      OR to_regclass('public.booking_payout_beneficiaries') IS NULL
      OR to_regclass('public.booking_supplier_payout_items') IS NULL
      OR to_regprocedure('public.create_booking_supplier_payout(uuid,uuid,uuid,uuid,text,text,text,uuid)') IS NULL
      OR to_regprocedure('public.succeed_booking_supplier_payout(uuid,text,text,bigint,text,text,uuid,text,text)') IS NULL
      OR to_regclass('public.booking_recovery_cases') IS NULL
      OR to_regclass('public.booking_recovery_events') IS NULL
      OR to_regclass('public.booking_recovery_actions') IS NULL
      OR to_regprocedure('public.decide_booking_recovery_action(uuid,uuid,uuid,boolean,text)') IS NULL
      OR to_regprocedure('public.record_booking_late_payout_success(uuid,uuid,text,bigint,text,text,text,text,jsonb)') IS NULL
      OR to_regclass('public.booking_authorization_decisions') IS NULL
      OR to_regprocedure(
        'public.evaluate_booking_authorization(uuid,uuid,text,text,text,text,uuid,text)') IS NULL
    THEN RAISE EXCEPTION 'required trust and booking schema was not installed'; END IF;
  END \$\$;" >/dev/null

echo "legacy schema upgrade dry run passed"
