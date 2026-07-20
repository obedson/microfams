# Database schema baseline

## Purpose

The historical SQL files in `backend/migrations` were incremental patches against an already populated Supabase project. They did not define the core `users`, `properties`, `bookings`, `groups`, `group_members`, `courses`, or `user_progress` tables, so a new environment could not be created from source control.

The repository now has a reproducible clean-install path:

- `000_core_schema.sql` defines identity, authentication support, farm-space booking, learning, and notification foundations.
- `create_nigeria_locations.sql` creates the integer state and LGA identifiers used by the API.
- `002_group_core_schema.sql` defines groups and memberships after location tables exist.
- `schema-manifest.txt` is the canonical order for the remaining migrations.
- `repair_group_wallet_ledger.sql` safely upgrades existing installations and repairs the group-ledger contract.

## Applying the schema

From `backend`, provide a PostgreSQL connection URL via the command argument, not a committed file:

```bash
./scripts/apply-migrations.sh "$SUPABASE_DB_URL"
```

Use a dedicated test/staging project before applying any migration to production. The connection URL must be stored as the `SUPABASE_DB_URL` Codespaces secret.

## Verification

Run the isolated clean-install contract test:

```bash
npm run test:schema
```

The test starts an ephemeral PostgreSQL 16 container, applies every manifest migration, and verifies:

- required tables are present;
- the group-creation RPC accepts integer state/LGA identifiers;
- a group credit updates the balance and creates an append-only group ledger transaction;
- a group transfer requires a matching approved consensus request;
- the transfer atomically updates the group balance, recipient wallet, and request status.

The container and its data are removed when the test finishes. CI runs this test for every pull request.

## Deliberately excluded legacy scripts

The manifest is authoritative. It intentionally excludes:

- `create_orders.sql`, because it defines an obsolete cart-shaped order table that `fix_orders_table.sql` immediately destroys;
- `insert_nigeria_locations.sql`, because location data is already seeded by `create_nigeria_locations.sql`;
- `create_admin_user.sql`, because fixed administrative credentials must never be part of automated environment creation;
- `verify_migrations.sql`, because executable assertions now live in the isolated schema test.

These files remain temporarily for migration history. They should not be run outside the canonical manifest.

## Production comparison

Before the baseline is promoted, export the current non-production Supabase schema and compare it with this clean install. That comparison is the reason `SUPABASE_DB_URL` is requested; no application or payment-provider credentials are needed for it.
