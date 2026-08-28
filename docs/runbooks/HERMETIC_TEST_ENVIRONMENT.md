# Hermetic test environment

This runbook covers the hermetic test configuration and seeded test tenants required for Version 1 release safety.

The backend test suite loads `backend/tests/setup.ts` through Jest and uses synthetic defaults only when a value is not already supplied. Unit tests must not require network access, production credentials, or real personal data.

## Stable tenant fixtures

`backend/tests/fixtures/tenantFixtures.ts` defines two unrelated synthetic organizations, users, and memberships. Tests should import these fixtures rather than inventing shared identifiers. Tenant-isolation tests must exercise both fixtures and prove that data owned by one cannot be read, changed, aggregated, exported, or inferred by the other.

## CI checks

Run from the Codespace:

```bash
npm --prefix backend run verify:hermetic
npm --prefix backend test -- --runInBand tests/fixtures/tenantFixtures.test.ts
npm --prefix backend run test:unit
```

The verification command fails closed when unit-test defaults are not loopback-only,
synthetic tenant fixtures are missing, or recognizable live secrets are committed.

A unit test that attempts to contact the configured local Supabase URL is not hermetic and must be moved to the database-integration suite or supplied with a deterministic adapter. Never point the test defaults at a hosted or production database.

## Failure and recovery

If tests become dependent on external state, stop the affected CI job, preserve its logs, and restore deterministic adapters or fixtures. Do not repair a test by adding live credentials. If fixture identifiers must change, update every dependent seed and isolation assertion in one reviewed change, then run unit, database integration, schema, and reconciliation checks.

Test secrets are recognizable non-production placeholders. Real provider tokens, identity values, phone numbers, or bank details must not be committed or added to fixtures.
