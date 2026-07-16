# Legacy Supabase upgrade assessment

Assessment date: 2026-07-16

## Scope and safety

The `SUPABASE_DB_URL` Codespaces secret was used only for read-only PostgreSQL metadata queries and a schema-only `pg_dump`. No migration, insert, update, or delete was executed against Supabase.

The schema-only dump was restored to an ephemeral PostgreSQL 17 container. Proposed upgrade migrations were applied only inside that disposable container.

## Current project profile

The Supabase project runs PostgreSQL 17.6 and contains 30 public tables. It represents the legacy platform schema, not an empty staging database.

The following Version 1 foundations are absent:

- organizations, memberships, branding, invitations, and organization audit log;
- feature flags, scoped overrides, and feature-flag audit log;
- notifications;
- explicit organization ownership on operational records.

The remote project also contains a legacy `products` table alongside `marketplace_products`. This assessment preserves both; consolidation must be an explicit marketplace migration rather than a destructive rename or drop.

## Compatibility differences

Important differences from a clean Version 1 installation include:

- legacy group memberships have `role` and `member_status`, but lack the newer `status`, `is_active`, `created_at`, and `updated_at` lifecycle fields;
- wallet transactions require a user wallet and cannot represent group-owned ledger entries;
- bookings and several other tables allow nullable ownership foreign keys;
- courses store content as text rather than the clean baseline's JSONB contract;
- booking communications include legacy media fields not present in the clean baseline;
- numerous legacy columns and indexes must be preserved during upgrade.

The upgrade path therefore applies targeted compatibility migrations. It must not replay the entire clean-install manifest against this project.

## Data readiness

Aggregate ownership checks found no orphaned ownership chain for properties, groups, farm records, wallets, wallet transactions, contributions, receipts, refunds, orders, or marketplace products.

Bookings are the exception:

- total booking rows: 651;
- rows with neither farmer nor property: 625;
- these rows were created in a two-minute batch on 2026-03-10;
- their states include paid/confirmed, completed, cancelled, and failed combinations.

These records cannot be assigned to a real customer or provider organization. The migration preserves them in a suspended system quarantine organization with no memberships. They are invisible to tenant users, remain available for audit, and are not deleted. Aggregate quarantine counts are written to the organization audit log.

## Verified upgrade order

The following targeted order passes against a schema-only clone of the Supabase project:

1. `create_organizations.sql`
2. `repair_group_wallet_ledger.sql`
3. `add_domain_tenant_ownership.sql`
4. `create_feature_flags.sql`

The verification also inserts a representative ownerless paid booking locally and proves that it is quarantined without creating a membership for the quarantine organization.

## Repeatable verification

From the `backend` directory, with `SUPABASE_DB_URL` available in the environment:

```bash
npm run test:schema:legacy
```

This command performs a schema-only export, creates an ephemeral PostgreSQL 17 database, restores the schema, applies the targeted migrations locally, validates quarantine behavior, and removes the container. It does not alter Supabase.

## Promotion recommendation

Do not apply the upgrade to production yet. The next safe step is to run the targeted migration transaction on a disposable Supabase branch or a separate staging clone containing representative data, validate the application APIs against it, and retain a tested rollback/restore point. Provider and payment credentials are unrelated to this database upgrade.
