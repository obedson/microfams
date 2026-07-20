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

Exit gate: sandbox and live-contract tests, privacy review, replay protection, and negative-path E2E tests.

## Phase 3 — Financial core

- [x] Approve accounting and money specifications.
  - FC-01 through FC-08 in [`docs/specs/FINANCIAL_CORE.md`](specs/FINANCIAL_CORE.md) were approved by the product owner on 2026-07-19.
- [ ] Replace the current wallet transaction model with first-class ledger accounts and balanced postings.
- [ ] Add idempotent payment orchestration, provider adapters, webhooks, settlement, fees, refunds, reversals, and reconciliation.
- [ ] Implement individual, group, escrow, savings, investment, clearing, fee, and settlement accounts.
- [ ] Add statements, limits, approvals, freezes, closures, and incident recovery.

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
