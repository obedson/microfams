#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

identity_platform_binding_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.platform_identity_bindings') IS NOT NULL")"
if [[ "$identity_platform_binding_present" == "f" ]]; then
  migrations+=(install_identity_platform_binding.sql)
fi

identity_challenge_expiry_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure('public.expire_identity_verification_challenges(integer,timestamp with time zone)') IS NOT NULL")"
if [[ "$identity_challenge_expiry_present" == "f" ]]; then
  migrations+=(install_identity_challenge_expiry.sql)
fi

identity_provider_recovery_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure('public.record_identity_provider_deferred(uuid)') IS NOT NULL")"
if [[ "$identity_provider_recovery_present" == "f" ]]; then
  migrations+=(install_identity_provider_recovery.sql)
fi


# Later booking and savings migrations use the canonical purpose catalogue.
# Some hosted schemas have the ledger tables but predate this additive layer.
financial_account_provisioning_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.financial_account_purpose_rules') IS NOT NULL
    AND to_regprocedure('public.provision_financial_account(uuid,uuid,text,text,text,text,text,uuid,date,text)') IS NOT NULL")"
if [[ "$financial_account_provisioning_present" == "f" ]]; then
  migrations+=(create_financial_account_provisioning.sql)
fi

group_asset_accounting_mappings_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.group_asset_journal_mappings') IS NOT NULL")"
if [[ "$group_asset_accounting_mappings_present" == "f" ]]; then
  migrations+=(install_group_asset_accounting_mappings.sql)
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

booking_authorization_completion_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure(
    'public.authorize_booking_payout_resource(uuid,uuid,text,text,uuid)') IS NOT NULL
    AND to_regprocedure(
    'public.decide_booking_dispute_resolution_authorized(uuid,uuid,uuid,boolean,text,text,uuid)') IS NOT NULL")"
if [[ "$booking_authorization_completion_present" == "f" ]]; then
  migrations+=(install_booking_authorization_completion.sql)
fi

booking_operational_statements_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regprocedure(
    'public.read_booking_settlement_statement(uuid,uuid,uuid)') IS NOT NULL")"
if [[ "$booking_operational_statements_present" == "f" ]]; then
  migrations+=(install_booking_operational_statements.sql)
fi

booking_notification_outbox_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass(
    'public.booking_domain_notification_outbox') IS NOT NULL
    AND to_regprocedure(
      'public.claim_booking_domain_notifications(text,timestamp with time zone,integer,integer)') IS NOT NULL")"
if [[ "$booking_notification_outbox_present" == "f" ]]; then
  migrations+=(install_booking_notification_outbox.sql)
fi

group_lifecycle_foundation_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.group_lifecycle_events') IS NOT NULL
    AND to_regclass('public.group_legacy_reviews') IS NOT NULL
    AND to_regprocedure(
      'public.transition_group_lifecycle(uuid,uuid,uuid,text,text,integer,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_lifecycle_foundation_present" == "f" ]]; then
  migrations+=(install_group_lifecycle_foundation.sql)
fi

group_constitution_offices_present="$(docker exec "$container" psql --username postgres --dbname microfams \
  --no-psqlrc --tuples-only --no-align \
  --command "SELECT to_regclass('public.group_constitutions') IS NOT NULL
    AND to_regclass('public.group_office_assignments') IS NOT NULL
    AND to_regprocedure(
      'public.activate_group_with_constitution(uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_constitution_offices_present" == "f" ]]; then
  migrations+=(install_group_constitution_offices.sql)
fi

group_membership_invitations_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_membership_invitations') IS NOT NULL AND to_regclass('public.group_membership_events') IS NOT NULL AND to_regprocedure('public.accept_group_membership_invitation(uuid,uuid,uuid,text,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_membership_invitations_present" == "f" ]]; then
  migrations+=(install_group_membership_invitations.sql)
fi

group_proposals_voting_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_proposals') IS NOT NULL AND to_regclass('public.group_voting_snapshots') IS NOT NULL AND to_regclass('public.group_vote_history') IS NOT NULL AND to_regprocedure('public.close_group_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_proposals_voting_present" == "f" ]]; then
  migrations+=(install_group_proposals_voting.sql)
fi

group_admission_payments_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_entry_requirement_versions') IS NOT NULL AND to_regclass('public.group_membership_payment_allocations') IS NOT NULL AND to_regprocedure('public.activate_paid_group_membership(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_admission_payments_present" == "f" ]]; then
  migrations+=(install_group_admission_payments.sql)
fi

group_member_discipline_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_member_discipline_cases') IS NOT NULL AND to_regclass('public.group_member_discipline_appeals') IS NOT NULL AND to_regprocedure('public.execute_group_member_discipline(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_member_discipline_present" == "f" ]]; then
  migrations+=(install_group_member_discipline_appeals.sql)
fi

group_office_lifecycle_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regprocedure('public.execute_group_office_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NOT NULL AND to_regprocedure('public.delegate_group_office(uuid,uuid,uuid,text,uuid,uuid,timestamp with time zone,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_office_lifecycle_present" == "f" ]]; then
  migrations+=(install_group_office_lifecycle.sql)
fi

group_contributions_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_contribution_products') IS NOT NULL AND to_regclass('public.group_contribution_rule_versions') IS NOT NULL AND to_regprocedure('public.allocate_group_contribution_payment(uuid,uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_contributions_present" == "f" ]]; then
  migrations+=(install_group_contributions.sql)
fi

group_contribution_cycles_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_contribution_cycles') IS NOT NULL")"
if [[ "$group_contribution_cycles_present" == "f" ]]; then
  migrations+=(install_group_contribution_cycles.sql)
fi

group_treasury_disbursements_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_treasury_disbursements') IS NOT NULL")"
if [[ "$group_treasury_disbursements_present" == "f" ]]; then
  migrations+=(install_group_treasury_disbursements.sql)
fi

group_committees_meetings_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_committees') IS NOT NULL AND to_regclass('public.group_meetings') IS NOT NULL AND to_regclass('public.group_meeting_minutes') IS NOT NULL AND to_regprocedure('public.hold_group_meeting(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$group_committees_meetings_present" == "f" ]]; then
  migrations+=(install_group_committees_meetings.sql)
fi

group_treasury_external_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.group_treasury_disbursements') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='payouts' AND column_name='group_treasury_disbursement_id')")"
if [[ "$group_treasury_external_present" == "f" ]]; then
  migrations+=(install_group_treasury_external_disbursements.sql)
fi

savings_product_foundation_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.savings_products') IS NOT NULL AND to_regprocedure('public.enrol_savings_product(uuid,uuid,uuid,bigint,text,text,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$savings_product_foundation_present" == "f" ]]; then
  migrations+=(install_savings_product_foundation.sql)
fi

savings_contributions_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.savings_contributions') IS NOT NULL AND to_regprocedure('public.service_savings_standing_order(uuid,uuid,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$savings_contributions_present" == "f" ]]; then
  migrations+=(install_savings_contributions_standing_orders.sql)
fi

savings_accruals_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.savings_accrual_batches') IS NOT NULL AND to_regprocedure('public.approve_savings_accrual_batch(uuid,uuid,uuid,text,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$savings_accruals_present" == "f" ]]; then
  migrations+=(install_savings_accrual_posting.sql)
fi

savings_withdrawals_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.savings_withdrawals') IS NOT NULL AND to_regprocedure('public.review_savings_withdrawal(uuid,uuid,uuid,text,text,text,uuid,timestamp with time zone)') IS NOT NULL")"
if [[ "$savings_withdrawals_present" == "f" ]]; then
  migrations+=(install_savings_withdrawals.sql)
fi

savings_reporting_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regprocedure('public.read_member_savings_statement(uuid,uuid,uuid,date,date,timestamp with time zone,integer,integer)') IS NOT NULL AND to_regprocedure('public.read_savings_reconciliation(uuid,uuid,text,timestamp with time zone,integer,integer,integer)') IS NOT NULL")"
if [[ "$savings_reporting_present" == "f" ]]; then
  migrations+=(install_savings_statements_reconciliation.sql)
fi

savings_provider_certification_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.savings_provider_certifications') IS NOT NULL AND to_regprocedure('public.read_savings_provider_readiness(uuid,uuid,text,text,text,text,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$savings_provider_certification_present" == "f" ]]; then
  migrations+=(install_savings_provider_certification.sql)
fi

loan_product_foundation_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.loan_products') IS NOT NULL AND to_regprocedure('public.approve_loan_product_version(uuid,uuid,uuid,integer,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$loan_product_foundation_present" == "f" ]]; then
  migrations+=(install_loan_product_foundation.sql)
fi

loan_application_underwriting_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.loan_applications') IS NOT NULL AND to_regprocedure('public.decide_loan_adverse_review(uuid,uuid,uuid,text,text,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$loan_application_underwriting_present" == "f" ]]; then
  migrations+=(install_loan_application_underwriting.sql)
fi

loan_review_offers_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.loan_offers') IS NOT NULL AND to_regprocedure('public.accept_loan_offer(uuid,uuid,uuid,uuid,text,text,text,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$loan_review_offers_present" == "f" ]]; then
  migrations+=(install_loan_review_offers.sql)
fi

loan_repayment_schedules_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.loan_repayment_schedules') IS NOT NULL AND to_regprocedure('public.generate_loan_repayment_schedule(uuid,uuid,uuid,uuid,text,timestamp with time zone)') IS NOT NULL")"
if [[ "$loan_repayment_schedules_present" == "f" ]]; then
  migrations+=(install_loan_repayment_schedules.sql)
fi

loan_disbursement_orchestration_present="$(docker exec "$container" psql --username postgres --dbname microfams --no-psqlrc --tuples-only --no-align --command "SELECT to_regclass('public.loan_disbursements') IS NOT NULL AND to_regprocedure('public.begin_loan_disbursement(uuid,uuid,uuid,uuid,text,text,text,uuid,timestamp with time zone)') IS NOT NULL AND to_regprocedure('public.succeed_loan_disbursement_payout(uuid,text,text,bigint,text,text,uuid,text,text)') IS NOT NULL")"
if [[ "$loan_disbursement_orchestration_present" == "f" ]]; then
  migrations+=(install_loan_disbursement_orchestration.sql)
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
      OR to_regprocedure(
        'public.read_booking_supplier_payout(uuid,uuid,uuid)') IS NULL
      OR to_regprocedure(
        'public.decide_booking_dispute_resolution_authorized(uuid,uuid,uuid,boolean,text,text,uuid)') IS NULL
      OR to_regclass('public.group_proposals') IS NULL
      OR to_regclass('public.group_voting_snapshots') IS NULL
      OR to_regclass('public.group_vote_history') IS NULL
      OR to_regprocedure(
        'public.cancel_group_proposal(uuid,uuid,uuid,uuid,integer,text,uuid,timestamp with time zone)') IS NULL
      OR to_regclass('public.group_entry_requirement_versions') IS NULL
      OR to_regclass('public.group_membership_payment_allocations') IS NULL
      OR to_regprocedure(
        'public.activate_paid_group_membership(uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone)') IS NULL
      OR to_regclass('public.group_member_discipline_cases') IS NULL
      OR to_regclass('public.group_member_discipline_appeals') IS NULL
      OR to_regprocedure(
        'public.execute_group_member_discipline(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NULL
      OR to_regclass('public.group_contribution_products') IS NULL
      OR to_regclass('public.group_contribution_rule_versions') IS NULL
      OR to_regclass('public.group_contribution_allocations') IS NULL
      OR to_regprocedure(
        'public.execute_group_contribution_rule_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamp with time zone)') IS NULL
      OR to_regprocedure(
        'public.allocate_group_contribution_payment(uuid,uuid,uuid,uuid,uuid,uuid,uuid,timestamp with time zone)') IS NULL
      OR to_regclass('public.savings_products') IS NULL
      OR to_regclass('public.savings_contributions') IS NULL
      OR to_regclass('public.savings_accrual_batches') IS NULL
      OR to_regclass('public.savings_withdrawals') IS NULL
      OR to_regprocedure(
        'public.read_member_savings_statement(uuid,uuid,uuid,date,date,timestamp with time zone,integer,integer)') IS NULL
      OR to_regprocedure(
        'public.read_savings_reconciliation(uuid,uuid,text,timestamp with time zone,integer,integer,integer)') IS NULL
      OR to_regclass('public.savings_provider_certifications') IS NULL
      OR to_regclass('public.savings_provider_certification_scenarios') IS NULL
      OR to_regprocedure(
        'public.read_savings_provider_readiness(uuid,uuid,text,text,text,text,text,timestamp with time zone)') IS NULL
      OR to_regclass('public.loan_products') IS NULL
      OR to_regclass('public.loan_product_versions') IS NULL
      OR to_regclass('public.loan_product_events') IS NULL
      OR to_regprocedure(
        'public.approve_loan_product_version(uuid,uuid,uuid,integer,text,timestamp with time zone)') IS NULL
      OR to_regclass('public.loan_applications') IS NULL
      OR to_regclass('public.loan_application_decisions') IS NULL
      OR to_regclass('public.loan_adverse_reviews') IS NULL
      OR to_regclass('public.loan_application_events') IS NULL
      OR to_regprocedure(
        'public.create_loan_application_draft(uuid,uuid,uuid,text,uuid,text,bigint,integer,bigint,bigint,integer,jsonb,uuid,text,text,text,text,text,timestamp with time zone)') IS NULL
      OR to_regprocedure(
        'public.decide_loan_adverse_review(uuid,uuid,uuid,text,text,text,timestamp with time zone)') IS NULL
      OR to_regclass('public.loan_offers') IS NULL
      OR to_regprocedure(
        'public.issue_loan_offer(uuid,uuid,uuid,bigint,integer,bigint,bigint,bigint,text[],text,text,timestamp with time zone,text[],text,text,timestamp with time zone)') IS NULL
      OR to_regprocedure(
        'public.accept_loan_offer(uuid,uuid,uuid,uuid,text,text,text,text,timestamp with time zone)') IS NULL
      OR to_regclass('public.loan_repayment_schedules') IS NULL
      OR to_regclass('public.loan_repayment_installments') IS NULL
      OR to_regprocedure(
        'public.generate_loan_repayment_schedule(uuid,uuid,uuid,uuid,text,timestamp with time zone)') IS NULL
      OR to_regclass('public.loan_condition_sets') IS NULL
      OR to_regclass('public.loan_disbursements') IS NULL
      OR to_regclass('public.loan_contracts') IS NULL
      OR to_regclass('public.loan_due_installments') IS NULL
      OR to_regprocedure(
        'public.begin_loan_disbursement(uuid,uuid,uuid,uuid,text,text,text,uuid,timestamp with time zone)') IS NULL
      OR to_regprocedure(
        'public.succeed_loan_disbursement_payout(uuid,text,text,bigint,text,text,uuid,text,text)') IS NULL
    THEN RAISE EXCEPTION 'required trust, booking, group, savings, and credit schema was not installed'; END IF;
  END \$\$;" >/dev/null

echo "legacy schema upgrade dry run passed"
