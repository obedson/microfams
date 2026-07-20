# Version 1 Test Strategy

## Purpose

Testing must demonstrate business correctness, tenant isolation, financial integrity, security, provider behaviour, and user journeys. Test files existing in the repository are not sufficient evidence unless they run deterministically in CI.

## Test environments

- Unit: no network or production credentials.
- Integration: disposable PostgreSQL/Supabase-compatible database, Redis, object storage emulator where practical, seeded tenants, deterministic clock.
- Provider contract: recorded or vendor sandbox responses with secrets supplied by CI.
- E2E: deployed preview environment with isolated sandbox tenant and provider test accounts.
- Live smoke: explicitly flagged, non-destructive tests using tightly limited real accounts and amounts.

Never run destructive tests against production.

## Required layers

### Unit tests

Tools: Jest, fast-check, framework-native utilities.

Cover domain services, money calculations, state transitions, pricing, permissions, feature flags, accounting rules, repayment schedules, dividend allocations, escrow conditions, agronomic rules, and error mapping. Provider clients are mocked at their interfaces.

Required properties include balanced postings, idempotency, conservation of value, non-negative constrained balances, deterministic allocation, legal transition graphs, and tenant-scoped identifiers.

### Integration tests

Cover real database migrations, transactions, row-level isolation, ledger posting, concurrent booking, outbox/jobs, webhook deduplication, reconciliation, file storage, cache invalidation, and provider sandbox adapters.

Every migration must be tested both forward and, where supported, through its documented recovery path.

### API tests

Tools: Supertest plus generated OpenAPI contract checks.

Cover authentication, tenant context, roles, feature flags, validation, pagination, idempotency, rate limits, error envelopes, privacy masking, and backward compatibility. Every sensitive endpoint requires unauthorized, wrong-tenant, wrong-role, disabled-flag, and replay tests.

### Frontend component tests

Tools: React Testing Library, user-event, accessibility matcher.

Cover loading, empty, success, validation, disabled-feature, permission-denied, offline, degraded-provider, and error states. Test behaviour and accessibility rather than implementation details.

### End-to-end tests

Tool: Playwright.

Critical journeys:

1. register → subscribe → identity verification → tenant/group membership;
2. create property → hold dates → price → pay → confirm → complete/refund;
3. fund group → reconcile webhook → approve withdrawal → individual wallet;
4. savings contribution → accrual → withdrawal;
5. loan application → approval → disbursement → repayment → delinquency path;
6. investment subscription → valuation → redemption;
7. escrow fund → fulfilment → release/dispute;
8. contribution cycle → accounting close → statements → dividend allocation;
9. farm setup → task/input/expense → harvest/yield report;
10. marketplace order → escrow → delivery → settlement;
11. course → assessment → certificate;
12. NGO/government tenant programme → enrolment → benefit → outcome report;
13. AI/weather/satellite feature enabled, disabled, unavailable, and permission-limited.

### Security and resilience tests

- secret scanning and dependency scanning;
- authorization and cross-tenant attack tests;
- webhook tampering and replay;
- sensitive-field leakage;
- rate limiting and abuse;
- backup restore and migration recovery;
- provider timeout, duplicate, delayed, and out-of-order callbacks;
- job retry/dead-letter handling;
- concurrency and load tests;
- accessibility and offline recovery.

## Financial test invariants

- Every posted journal transaction balances.
- Replaying a command or webhook does not create additional value.
- Reversal plus original has zero net effect except explicit non-refundable fees.
- Statements reconcile to journal entries.
- Cached balances reconcile to the ledger.
- Escrow assets equal escrow liabilities.
- Savings interest and dividends follow approved deterministic rules.
- Loan principal, interest, fees, payments, arrears, and write-offs reconcile.
- Tenant and member funds never cross without an approved posting.

## Test data

Use factories with stable IDs and seeded scenarios for at least two unrelated tenants. Never use real NINs, bank details, phone numbers, or production tokens in automated tests. Synthetic fixtures must be clearly marked.

## CI quality gates

Required checks for every PR:

1. formatting and static analysis;
2. backend typecheck and unit tests;
3. frontend typecheck and component tests;
4. mobile typecheck and tests;
5. migration and database integration tests;
6. API contract and authorization tests;
7. financial invariant/property tests;
8. Playwright smoke tests on preview;
9. dependency, secret, and code security scans.

Main-branch and release checks additionally run the full E2E, provider sandbox, reconciliation, accessibility, and performance suites.

## Initial baseline work

- Make existing Supabase-dependent tests hermetic.
- Replace placeholder tests and implementations with executable behaviour.
- Add missing frontend and mobile test commands.
- Introduce Playwright configuration and a minimal critical-path smoke suite.
- Create test factories, tenant fixtures, provider fakes, and a deterministic clock.
- Publish coverage and test reports without using coverage percentage as the sole release criterion.
