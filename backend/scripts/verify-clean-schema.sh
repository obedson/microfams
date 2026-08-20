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
      'payouts','payout_attempts','provider_events','reconciliation_runs','reconciliation_items','reconciliation_exceptions',
      'wallet_cache_write_capabilities','booking_settlement_contracts',
      'booking_settlement_allocations','booking_settlement_legacy_reviews',
      'booking_settlement_rules','booking_fee_rules','booking_settlement_holds',
      'booking_settlement_posting_links','booking_disputes',
      'booking_dispute_evidence','booking_dispute_events',
      'booking_domain_notification_outbox','group_lifecycle_events',
      'group_legacy_reviews','group_proposals','group_voting_snapshots',
      'group_voter_snapshot_members','group_vote_history','group_proposal_events',
      'group_entry_requirement_versions','group_entry_requirement_events',
      'group_membership_payment_allocations','group_contribution_products',
      'group_contribution_rule_versions','group_contribution_adjustment_rules',
      'group_contribution_allocations','group_contribution_events',
      'group_committees','group_committee_members','group_meetings',
      'group_meeting_attendance','group_meeting_minutes',
      'savings_products','savings_product_versions','savings_enrolments',
      'savings_product_events','savings_contributions',
      'savings_standing_orders','savings_standing_order_attempts',
      'savings_standing_order_events','savings_accrual_batches',
      'savings_accrual_items','savings_accrual_events',
      'savings_withdrawals','savings_withdrawal_events',
      'savings_provider_certifications','savings_provider_certification_scenarios',
      'savings_provider_certification_events','loan_products','loan_product_versions',
      'loan_product_events','loan_applications','loan_application_decisions',
      'loan_adverse_reviews','loan_application_events','loan_offers',
      'loan_contracts','loan_due_installments','loan_repayments',
      'loan_delinquency_assessments','loan_repayment_reversals'
    ]) AS required(name)
    WHERE to_regclass('public.' || required.name) IS NULL
  ) THEN
    RAISE EXCEPTION 'one or more required tables are missing';
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
    'public.read_booking_settlement_statement(uuid,uuid,uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'booking settlement statement function is missing';
  END IF;
  IF to_regprocedure(
    'public.read_member_savings_statement(uuid,uuid,uuid,date,date,timestamp with time zone,integer,integer)'
  ) IS NULL OR to_regprocedure(
    'public.read_savings_reconciliation(uuid,uuid,text,timestamp with time zone,integer,integer,integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'savings statement or reconciliation function is missing';
  END IF;
  IF to_regprocedure(
    'public.read_savings_provider_readiness(uuid,uuid,text,text,text,text,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.decide_savings_provider_certification(uuid,uuid,uuid,boolean,text,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'savings provider certification functions are missing';
  END IF;
  IF to_regprocedure(
    'public.create_loan_product_draft(uuid,uuid,text,text,text,jsonb,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.revise_loan_product(uuid,uuid,uuid,integer,jsonb,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.approve_loan_product_version(uuid,uuid,uuid,integer,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'loan product governance functions are missing';
  END IF;
  IF to_regprocedure(
    'public.create_loan_application_draft(uuid,uuid,uuid,text,uuid,text,bigint,integer,bigint,bigint,integer,jsonb,uuid,text,text,text,text,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.submit_loan_application(uuid,uuid,uuid,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.decide_loan_adverse_review(uuid,uuid,uuid,text,text,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'loan application underwriting functions are missing';
  END IF;
  IF to_regprocedure(
    'public.issue_loan_offer(uuid,uuid,uuid,bigint,integer,bigint,bigint,bigint,text[],text,text,timestamp with time zone,text[],text,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.accept_loan_offer(uuid,uuid,uuid,uuid,text,text,text,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.expire_loan_offer(uuid,uuid,uuid,uuid,text,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'loan review and offer functions are missing';
  END IF;
  IF to_regprocedure(
    'public.record_loan_repayment(uuid,uuid,uuid,uuid,bigint,date,uuid,text)'
  ) IS NULL OR to_regprocedure(
    'public.assess_loan_delinquency(uuid,uuid,uuid,uuid,date,uuid,text)'
  ) IS NULL OR to_regprocedure(
    'public.propose_loan_repayment_reversal(uuid,uuid,uuid,uuid,uuid,text,text,jsonb,uuid,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.decide_loan_repayment_reversal(uuid,uuid,uuid,text,text,uuid,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'loan repayment, delinquency, or correction function is missing';
  END IF;
  IF to_regprocedure(
    'public.claim_booking_domain_notifications(text,timestamp with time zone,integer,integer)'
  ) IS NULL OR to_regprocedure(
    'public.deliver_booking_domain_notification(uuid,text,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.fail_booking_domain_notification(uuid,text,text,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'booking notification outbox functions are missing';
  END IF;
  IF to_regprocedure(
    'public.execute_group_office_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.delegate_group_office(uuid,uuid,uuid,text,uuid,uuid,timestamp with time zone,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.end_group_office_delegation(uuid,uuid,uuid,text,uuid,text,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.service_expired_group_offices(uuid,uuid,uuid,uuid,timestamp with time zone)'
  ) IS NULL THEN RAISE EXCEPTION 'group office lifecycle functions are missing';
  END IF;
  IF to_regprocedure(
    'public.execute_group_contribution_rule_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.allocate_group_contribution_payment(uuid,uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.reverse_group_contribution_allocation(uuid,uuid,timestamp with time zone)'
  ) IS NULL THEN RAISE EXCEPTION 'group contribution functions are missing';
  END IF;
  IF to_regprocedure(
    'public.execute_group_committee_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.add_group_committee_member(uuid,uuid,uuid,uuid,uuid,text,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.end_group_committee_membership(uuid,uuid,uuid,uuid,text,uuid,timestamp with time zone)'
  ) IS NULL THEN RAISE EXCEPTION 'group committee functions are missing';
  END IF;
  IF to_regprocedure(
    'public.schedule_group_meeting(uuid,uuid,uuid,text,uuid,text,jsonb,timestamp with time zone,integer,text,text,integer,integer,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.record_group_meeting_attendance(uuid,uuid,uuid,uuid,uuid,text,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.hold_group_meeting(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.cancel_group_meeting(uuid,uuid,uuid,uuid,integer,text,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.draft_group_meeting_minutes(uuid,uuid,uuid,uuid,text,jsonb,uuid,uuid,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.approve_group_meeting_minutes(uuid,uuid,uuid,uuid,uuid,timestamp with time zone)'
  ) IS NULL THEN RAISE EXCEPTION 'group meeting functions are missing';
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
"$repo_root/backend/tests/schema/test-wallet-concurrency.sh" "$container"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-payout-orchestration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-payment-orchestration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-payment-recovery.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-payment-reconciliation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-reconciliation-investigation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-financial-rules.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-reconciliation-resolution.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-financial-account-provisioning.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-refund-orchestration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-reservations.sql"
"$repo_root/backend/tests/schema/test-booking-reservation-concurrency.sh" "$container"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-state-transitions.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-settlement-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-settlement-eligibility-fees.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-dispute-opening.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-dispute-resolution.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-supplier-payout.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-reversal-recovery.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-recovery-servicing.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-authorization-audit.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-authorization-completion.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-booking-notification-outbox.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-lifecycle-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-constitution-offices.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-membership-invitations.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-proposals-voting.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-admission-payments.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-member-discipline-appeals.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-office-lifecycle.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-contributions.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-contribution-cycles.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-treasury-disbursements.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-treasury-external-disbursements.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-treasury-emergency-expenditure.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-treasury-statements.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-group-committees-meetings.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-savings-product-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-savings-contributions-standing-orders.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-savings-accrual-posting.sql"
"$repo_root/backend/tests/schema/test-savings-accrual-concurrency.sh" "$container"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-savings-withdrawals.sql"
"$repo_root/backend/tests/schema/test-savings-withdrawal-concurrency.sh" "$container"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-savings-statements-reconciliation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-savings-provider-certification.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-product-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-application-underwriting.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-review-offers.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-repayment-schedules.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-disbursement-orchestration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-repayment-servicing.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-delinquency-servicing.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-repayment-reversal.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-identity-verification.sql"

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-organization-verification.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-platform-administration.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-trust-review-appeals.sql"

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-suspended-account-recovery.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-legal-hold-commands.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-retention-item-selection.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-financial-statements.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 \
  < "$repo_root/backend/tests/schema/test-trust-recovery-negative-e2e.sql"

echo "clean schema verification passed"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-restructuring.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-loan-writeoff.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-product-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-subscription-intents.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-offer-opening.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-subscription-settlement.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-fixed-unit-allocation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-oversubscription-planning.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-refund-obligations.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-oversubscribed-unit-execution.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-investment-refund-provider-submission.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-budget-amendments.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-pause-resume.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-completion.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-closeout.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-project-restricted-funds.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-document-versioning.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-document-access.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-shared-assets.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-reservations.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-condition-events.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-loss-events.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-reservation-cancellation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-custody-loss.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-lifecycle-cancellation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-disposal-proposals.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-transfer-proposals.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-accounting-mappings.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-disposal-accounting-facts.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-disposal-execution.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-transfer-accounting-facts.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-group-asset-transfer-execution.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-trial-balance.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-income-statement.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-balance-sheet.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-cash-flow.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-budgets.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-member-accounts.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-dividend-entitlement-snapshots.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-dividend-review-approval.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-dividend-payable-recognition.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-dividend-payment-servicing.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-accounting-audit-export.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-escrow-contract-foundation.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-escrow-wallet-funding.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-escrow-release-request.sql"
docker exec --interactive "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-escrow-release-approval.sql"
