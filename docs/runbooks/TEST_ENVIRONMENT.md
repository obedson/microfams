# Test Environment

Automated tests use synthetic data only. The shared fixture at `backend/tests/fixtures/tenantFixtures.ts` provides two stable, unrelated organizations and users for tenant-isolation scenarios.

## Configuration

Backend Jest loads `.env.test` through `backend/tests/setup.ts`. When values are absent, the setup supplies loopback Supabase settings and clearly marked test-only credentials. These defaults must never be used outside automated tests.

Database integration jobs require an isolated Supabase project through the `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` Actions secrets. The hosted legacy-schema rehearsal uses `SUPABASE_DB_URL`. Do not point either job at production.

## Fixture rules

Use `tenantFixture(0)` and `tenantFixture(1)` for cross-tenant tests. Keep organization, user, and membership IDs stable so snapshots and idempotency scenarios are reproducible. Tests must prove that a tenant cannot read, mutate, aggregate, export, or infer the other tenant's records.

Never add real NINs, bank details, phone numbers, provider tokens, or live webhook secrets to fixtures. Mark new fixtures synthetic and keep provider responses deterministic.

## Failure recovery

A local database failure is recovered by recreating the disposable test database and rerunning the affected suite. A CI credential failure is recovered by restoring the named Actions secret without printing its value. Do not change a production database to make a test pass.
