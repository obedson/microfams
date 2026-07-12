# Micro Fams Agent Instructions

## Mission

Micro Fams Version 1 is a multi-tenant Agro Operating System for smallholder and intending farmers, cooperatives, farm groups, agribusinesses, NGOs, and government programmes. Version 1 includes operations, finance, governance, education, commerce, intelligence, and institutional reporting. Do not silently defer an approved Version 1 domain.

## Sources of truth

1. This file defines repository-wide execution rules.
2. `docs/WORK_PLAN.md` defines delivery order and release gates.
3. Approved specifications under `.kiro/specs/` define business behaviour.
4. Code and migrations must agree with the approved specifications. A checked task is not proof that production behaviour exists.

## Working environment and delivery

- Work only in the `microfams-v1` GitHub Codespace; do not clone the repository to the user's computer.
- The Codespace stops after 10 idle minutes. GitHub retention is limited to 30 days, so every durable change must be committed and pushed.
- Deliver work through small, incremental draft pull requests using branches named `agent/<domain>-<change>`.
- Never mix unrelated domains in one PR.
- Inspect `git status` and the diff before staging. Preserve user changes.
- Use migrations for schema changes; never modify a production database manually.

## Architecture

- Build a modular monolith with explicit domain boundaries: platform, tenancy, identity, organizations, groups, booking, pricing, payments, ledger, wallets, savings, credit, investments, escrow, accounting, farm operations, inventory, assets, marketplace, education, intelligence, integrations, reporting, and notifications.
- Business logic belongs in domain services, not controllers, routes, React components, cron handlers, or provider adapters.
- Cross-domain work uses typed application interfaces and domain events. Do not introduce microservices or infrastructure CQRS without an approved architecture decision record.
- Provider integrations must sit behind interfaces with sandbox, live, and deterministic test adapters.

## Feature flags

- Every provider-dependent, regulated, institutional, or staged capability must have a backend-enforced flag.
- Frontend flags control presentation only; backend authorization and flags control execution.
- Flags are tenant-aware and environment-aware, auditable, typed, and default safely when configuration is missing.
- A live workflow may be enabled only when required credentials, configuration, reconciliation, and approval metadata are present.
- Disabling a flag must prevent new operations without corrupting or hiding existing records.

## Multi-tenancy and authorization

- Every tenant-owned record must carry an organization or tenant identifier and be protected at the database and service layers.
- Roles and permissions are scoped to organizations and resources. Global platform-admin privileges must be explicit and audited.
- Tests must prove isolation: one tenant cannot read, mutate, aggregate, export, or infer another tenant's data.

## Financial invariants

- Money uses integer minor units or a documented fixed-precision money type; never binary floating point.
- The journal is the financial source of truth. Balance snapshots are derived caches.
- Every posting balances debits and credits. Posted entries are immutable; corrections use reversals or compensating entries.
- All payment, webhook, transfer, settlement, and posting operations require idempotency keys and database uniqueness constraints.
- External money flows require reconciliation, explicit pending/failed/reversed states, and recoverable background processing.
- Never log secrets, raw identity numbers, full bank details, OTPs, or provider tokens.
- Financial rules must be approved in specifications before implementation.

## Data and integrations

- Store secrets only in GitHub Codespaces secrets or deployment secret managers. Never commit secret values.
- Personal and identity data must be minimized, encrypted where appropriate, masked in responses, and covered by retention rules.
- Provider webhooks must verify the raw payload signature, timestamp or replay protection where supported, and idempotency before mutation.
- Missing providers must use contract-compatible test adapters; do not fake a live success path.

## Testing requirements

Every behaviour change must include the appropriate layers from `docs/TEST_STRATEGY.md`:

- unit tests for domain rules and calculations;
- integration tests for database transactions, tenancy, queues, and adapters;
- API tests for contracts, authentication, authorization, validation, and flags;
- frontend component tests for user states and accessibility;
- end-to-end tests for critical user journeys;
- reconciliation and invariant tests for all financial domains.

Do not mark a task complete because code exists. Required tests must pass, placeholders must be removed, and acceptance criteria must be demonstrated.

## Definition of done

A Version 1 task is done only when its specification is approved, implementation and migrations are complete, feature flags and permissions are enforced, tests pass in CI, documentation and observability exist, security checks pass, and rollback/recovery behaviour is documented.
