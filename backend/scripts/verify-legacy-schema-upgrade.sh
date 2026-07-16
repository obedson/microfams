#!/usr/bin/env bash
set -euo pipefail

repo_root=/workspaces/microfams
container="microfams-upgrade-$RANDOM-$RANDOM"
cleanup() { docker rm --force "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

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
for _ in $(seq 1 30); do
  docker exec "$container" pg_isready --username postgres --dbname microfams >/dev/null 2>&1 && break
  sleep 1
done

docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 < "$repo_root/backend/tests/schema/test-schema-bootstrap.sql" >/dev/null
docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
  --command 'CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;' \
  >/dev/null
docker exec --interactive "$container" psql --username postgres --dbname microfams \
  --set ON_ERROR_STOP=1 < /tmp/microfams-remote-public-schema.sql >/dev/null

# Reproduce the ownerless booking shape present in the legacy test project.
docker exec "$container" psql --username postgres --dbname microfams --set ON_ERROR_STOP=1 \
  --command "INSERT INTO bookings(start_date, end_date, total_amount, status, payment_status) VALUES (CURRENT_DATE, CURRENT_DATE + 30, 1000, 'confirmed', 'paid');" \
  >/dev/null

for migration in create_organizations.sql repair_group_wallet_ledger.sql add_domain_tenant_ownership.sql create_feature_flags.sql; do
  echo "dry-run applying $migration"
  docker exec --interactive "$container" psql --username postgres --dbname microfams \
    --set ON_ERROR_STOP=1 < "$repo_root/backend/migrations/$migration" >/dev/null
done

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

echo "legacy schema upgrade dry run passed"
