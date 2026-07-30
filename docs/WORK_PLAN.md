# Micro Fams Version 1 Work Plan

## Objective

Deliver a production-grade, multi-tenant Agro Operating System covering trust, finance, cooperative governance, farm operations, skills, commerce, and intelligent management. Capabilities may be enabled or disabled through backend feature flags, but all approved Version 1 workflows must be implemented and testable.

## Delivery model

- Codespace-only development.
- Incremental draft PRs.
- Modular-monolith domain boundaries.
- Specifications before financial implementation.
- Sandbox and live adapters share the same contracts.
- Each phase has automated release gates; checked task documents are not accepted as evidence by themselves.

## Current baseline assessment

The repository contains 384 tracked files: 168 backend, 131 frontend, 43 mobile, 33 migrations, and 24 test files. It has useful booking, marketplace, course, group, wallet, receipt, analytics, and mobile foundations. It is not currently release-ready.

Confirmed blockers include:

- no GitHub Actions workflows;
- exposed deployment credentials requiring rotation and history cleanup;
- backend tests that cannot initialize consistently without Supabase test configuration;
- dependency audit findings, including a critical advisory;
- check-then-insert booking creation without a tracked database concurrency invariant;
- placeholder payment-timeout lookup, refund integration, MFA verification, and notifications;
- payment-retry URL generation that is not a real provider initialization;
- inconsistent NIN verification requirements across specifications and prompts;
- a group-credit ledger function whose account model cannot guarantee a corresponding journal entry;
- specifications and task checkboxes that overstate verified implementation.

## Version 1 domain map

1. Platform kernel: configuration, feature flags, tenancy, RBAC/ABAC, audit, events, jobs, observability.
2. Identity and trust: authentication, profiles, NIN/BVN or approved KYC, OTP, organization verification, consent.
3. Organizations and groups: cooperative structures, committees, meetings, voting, documents, roles, membership.
4. Financial core: chart of accounts, double-entry ledger, reconciliation, wallets, payments, settlement, fees.
5. Savings, credit, investment, dividends, and escrow: configurable products and approval-controlled live adapters.
6. Booking and pricing: inventory/availability, holds, pricing, payments, refunds, disputes, payouts.
7. Cooperative accounting: journals, periods, trial balance, statements, budgets, member accounts, audit exports.
8. Farm operations: farms, plots, crops, livestock, tasks, workers, attendance, inputs, yields, expenses.
9. Assets and inventory: equipment, storage, stock, maintenance, internal booking, depreciation metadata.
10. Marketplace and education: products, services, delivery, escrow, courses, paths, certificates, offline learning.
11. Intelligence: weather, satellite, maps, agronomic rules, analytics, forecasts, AI assistants.
12. Institutional portals: tenant-isolated NGO and government programmes, cohorts, interventions, monitoring, exports.
13. Web, mobile, notifications, accessibility, and offline synchronization.

## Phase 0 — Foundation and release safety

- [ ] Rotate exposed secrets and remove sensitive values from history.
- [ ] Establish CI for backend, frontend, mobile, migrations, security, and E2E.
- [ ] Create hermetic test configuration and seeded test tenants.
- [ ] Resolve critical dependency and webhook-security findings.
- [ ] Implement typed configuration validation and secret inventory.
- [ ] Implement backend feature-flag service with tenant/environment overrides and audit records.
- [ ] Add architecture decision records and API/error conventions.
- [ ] Replace placeholder completion claims with evidence-linked status.

Exit gate: clean builds, deterministic tests, secret scan, dependency gate, and documented recovery.

## Phase 1 — Multi-tenant platform kernel

- [ ] Organization/tenant model and migration.
- [ ] Tenant context propagation and database isolation.
- [ ] Organization roles, permissions, branding, settings, and reporting scopes.
- [x] Global platform administration separated from tenant administration.
- [ ] Domain-event outbox and durable job processing.
- [ ] Audit, metrics, tracing, health checks, and correlation IDs.

Exit gate: automated tenant-isolation tests across database, API, exports, jobs, and analytics.

## Phase 2 — Trust and identity

- [ ] Approve one authoritative NIN ownership flow.
- [ ] Implement provider-neutral KYC contracts, OTP, consent, retries, and redaction.
- [ ] Add organization verification and optional BVN/face-verification adapters.
- [ ] Add identity review, suspension, appeal, retention, and audit workflows.
  - [x] Trust review cases, independent appeals, tenant/platform suspension boundaries, audit evidence, and retention dry-run foundation.
  - [x] Add single-purpose suspended-account recovery and appeal tokens.
  - [x] Add legal-hold placement/release command history.
  - [x] Add the retention item-selection worker.
  - [x] Add negative-path trust and recovery E2E coverage.

Exit gate: sandbox and live-contract tests, privacy review, replay protection, and negative-path E2E tests.

## Phase 3 — Financial core

- [x] Approve accounting and money specifications.
  - FC-01 through FC-08 in [`docs/specs/FINANCIAL_CORE.md`](specs/FINANCIAL_CORE.md) were approved by the product owner on 2026-07-19.
- [x] Replace the current wallet transaction model with first-class ledger accounts and balanced postings.
  - [x] Add audited tenant cutover, protected derived caches, reservations, reversals, rollback controls, and concurrent overcommit coverage.
- [ ] Add idempotent payment orchestration, provider adapters, webhooks, settlement, fees, refunds, reversals, and reconciliation.
  - [x] Remove direct backend-role mutation rights and run the payment/refund/reversal/settlement SQL contract in clean-schema CI.
  - [x] Persist reconciliation runs and source evidence atomically with tenant validation and replay protection.
  - [x] Add authorized, auditable, and idempotent reconciliation exception investigation transitions.
  - [x] Add maker-checker resolution and write-off with immutable evidence and compensating-journal validation.
- [ ] Implement individual, group, escrow, savings, investment, clearing, fee, and settlement accounts.
  - [x] Add canonical FC-02 account purposes and idempotent tenant provisioning for every required V1 account family.
- [ ] Add statements, limits, approvals, freezes, closures, and incident recovery.
  - [x] Add reproducible journal-derived personal and group wallet statements.

Exit gate: invariant/property tests, reconciliation to zero unexplained variance, concurrency tests, and provider sandbox certification.

## Phase 4 — Financial products

Specifications requiring approval before code:

- [ ] savings products, interest/accrual, standing orders, goals, early withdrawal;
- [ ] credit products, eligibility, underwriting inputs, schedules, delinquency, restructuring, write-off;
- [ ] investments, units, valuation, subscriptions, redemptions, disclosures;
- [ ] escrow funding, release conditions, disputes, partial release, expiry;
- [ ] dividends/profit sharing, eligibility date, allocation, withholding metadata, approval and payment.

Exit gate: approved rules, complete ledger mappings, simulations, and feature-flagged live tests.

## Phase 5 — Booking, groups, and cooperative accounting

- [ ] Atomic booking creation, reservation holds, state transitions, pricing snapshots, payouts, refunds, disputes.
  - [x] Add atomic reservations, immutable pricing snapshots, canonical cancellation/refunds, and idempotent owner approval/completion transitions.
  - [x] Approve BS-01 through BS-12 booking settlement, dispute, fee, refund, and supplier-payout rules in [`docs/specs/BOOKING_SETTLEMENTS.md`](specs/BOOKING_SETTLEMENTS.md). Approved by the product owner on 2026-07-28.
  - [x] Add booking settlement contracts, booking-specific escrow custody, refund/reversal allocations, legacy review quarantine, and acquisition/servicing flags.
  - [x] Add effective-dated settlement and fee rules, maker-checker activation, completion-time eligibility snapshots, hold-aware release checks, and balanced cross-tenant supplier/platform accounting.
  - [x] Add BS-06 customer/support dispute opening, atomic contested-amount freezes, append-only malware-aware evidence, and tenant-safe timelines.
  - [x] Add BS-07 versioned response rules and notices, monotonic dispute review, conserved maker-checker resolutions, pending-refund reservations, cumulative partial releases and recovery commands.
  - [x] Add BS-08 encrypted verified provider beneficiaries, destination-change holds and independent approval, release-scoped supplier payouts, recoverable servicing, restoration on failure, and exact success postings.
  - [x] Add BS-09 reversal intake that preserves original evidence, classifies escrow/unpaid/post-payout exposure, creates balanced cross-tenant recovery accounting, and forbids automatic unrelated-wallet debit.
  - [x] Add BS-09 recovery servicing with evidenced maker-checker repayment, provider recovery, insurance, bounded future-settlement offsets and write-offs, plus late-payout-success reconciliation that never silently repays terminal payouts.
  - [x] Add BS-10A durable organization-scoped authorization decisions and audited API permission gates for dispute opening/resolution and settlement reads/releases, with privacy-minimized denial evidence.
  - [x] Add BS-10B payout read/servicing resource authorization, masked payout-state reads, and neutral organization-scoped independent dispute approval.
- [ ] Group treasury, contributions, projects, committees, meetings, voting, documents, and shared assets.
- [ ] Chart of accounts, fiscal periods, journals, trial balance, income statement, balance sheet, cash flow, budgets, member accounts, dividends, loans, and audit exports.

## Phase 6 — Farm operations, assets, marketplace, and education

- [ ] Farm/plot/livestock records, calendars, workers, tasks, inputs, yields, expenses, evidence, and offline sync.
- [ ] Inventory, warehouses, equipment, maintenance, internal resource booking, and utilization.
- [ ] Marketplace orders, services, delivery, ratings, escrow, settlements, returns, and disputes.
- [ ] Courses, learning paths, assessments, certificates, extension-officer tools, group learning, offline content.

## Phase 7 — Intelligence and institutional portals

- [ ] Provider-neutral weather, mapping, and satellite adapters.
- [ ] Agronomic recommendations with provenance and confidence.
- [ ] Tenant-scoped AI assistant using service APIs, permission checks, citations, audit, and human confirmation for actions.
- [ ] Government/NGO programme setup, targeting, cohorts, benefits, monitoring, outcomes, dashboards, and exports.

## Phase 8 — Release validation

- [ ] Full unit, integration, API, component, E2E, security, performance, accessibility, recovery, and reconciliation suites.
- [ ] Feature-flag matrix tested in enabled, disabled, misconfigured, and degraded-provider states.
- [ ] Production runbooks, incident response, backup/restore, migration rollback, and support procedures.
- [ ] Version 1 release candidate and acceptance evidence.

## Incremental PR sequence

1. Foundation documentation and test architecture.
2. CI, configuration validation, secret remediation, and baseline tests.
3. Feature flags and tenant kernel.
4. Identity specification and implementation.
5. Ledger/accounting specification and financial core.
6. Booking/payment hardening.
7. Group governance and treasury.
8. Financial products, one approved product specification per PR series.
9. Farm operations and assets.
10. Marketplace and education.
11. Intelligence integrations.
12. Institutional portals.
13. Release hardening.

Each PR records scope, migrations, flags, credentials, threat considerations, test evidence, rollback, and unresolved decisions.
