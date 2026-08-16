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
- [x] Normalize browser API deployment URLs and restrict production/preview CORS origins.
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

- [x] Approve the cross-product rules in [`docs/specs/FINANCIAL_MODULES_APPROVAL_SPEC.md`](specs/FINANCIAL_MODULES_APPROVAL_SPEC.md). Approved by the product owner on 2026-08-09.
- [ ] savings products, interest/accrual, standing orders, goals, early withdrawal;
  - [x] Add SAV-01 versioned products, immutable disclosures, maker-checker activation, tenant-isolated enrolment, idempotency, and canonical savings accounts.
  - [x] Add SAV-02 atomic manual contributions, consent-backed standing orders, no-debt failed attempts, hold-aware availability, lifecycle servicing, and worker recovery.
  - [x] Add SAV-03 completed-day simple-return accruals, immutable formula snapshots, rejection recovery, independent approval, and balanced accrued-return posting.
  - [x] Add SAV-04 governed withdrawals into personal wallets with lock-rule snapshots, fees or return forfeiture, liability reservations, maker-checker settlement, and exactly-once recovery.
  - [x] Add SAV-05 journal-derived member statements and tenant finance reconciliation controls with servicing-safe feature flags.
  - [x] Add SAV-06 provider-neutral certification evidence, zero-variance scenarios, maker-checker decisions, and fail-closed tenant acquisition readiness.
  - [ ] Add contributions, standing orders, accruals, withdrawals, servicing statements, reconciliation, and provider certification.
- [ ] credit products, eligibility, underwriting inputs, schedules, delinquency, restructuring, write-off;
  - [x] Add CRD-01 versioned loan products, complete rule snapshots, immutable disclosures, revision history, tenant isolation, idempotency, and maker-checker activation.
  - [x] Add CRD-02 tenant-scoped applications, pinned product/disclosure facts, deterministic eligibility and affordability decisions, explainable adverse notices, and independent human review.
  - [x] Add CRD-03 independent manual credit review, immutable revised offers, exact borrower acceptance evidence, expiry servicing, and pre-acceptance withdrawal.
  - [x] Add CRD-04 immutable contractual repayment schedules with disbursement-relative timing, deterministic allocation, and exact accepted-offer reconciliation.
  - [x] Add CRD-05 versioned conditions precedent, independently verified encrypted destinations, provider-neutral disbursement orchestration, confirmed-success receivable activation, calendar due dates, and late-success reconciliation quarantine.
  - [x] Add CRD-06 governed repayment allocation, balanced posting, payoff transitions, and fail-closed fee-bearing servicing.
  - [x] Add CRD-07 deterministic arrears classification from pinned product stages with immutable assessment evidence.
  - [x] Add CRD-08 maker-checker reversal of settled zero-interest repayments with linked compensating journals.
  - [x] Add CRD-09 maker-checker zero-interest restructuring with immutable prior schedules and principal-conserving replacement installments.
  - [x] Add CRD-10 maker-checker principal write-off for defaulted zero-interest loans with balanced credit-loss accounting.
- [ ] investments, units, valuation, subscriptions, redemptions, disclosures;
  - [x] Add INV-01 governed investment products, immutable risk disclosures, pro-rata oversubscription defaults, and independent compliance approval.
  - [x] Add INV-02 disclosure-bound pending subscription intents with offer, amount, jurisdiction, tenant, and replay controls; no cash or unit allocation.
  - [x] Add INV-03 governed approved-to-open offer activation with window validation, replay protection, and subscription gating.
  - [x] Add INV-04 verified provider-settlement binding for pending subscriptions without duplicate journals or unit allocation.
  - [x] Add INV-05 immutable fixed-price unit allocation after non-oversubscribed offers close; defer governed oversubscription, valuation, and redemption.
  - [x] Add INV-06 deterministic oversubscription plans with refund obligations and independent approval; execution remains disabled.
  - [x] Add INV-07 settlement-linked refund-obligation recognition with balanced liability reclassification; provider submission and oversubscribed unit execution remain disabled.
  - [x] Add INV-08 idempotent oversubscribed unit execution after every required refund obligation and recognition journal exists; provider submission remains disabled.
  - [x] Add INV-09 durable original-provider refund submission attempts with deterministic/sandbox routing, masked evidence, and non-final synchronous results; recovery and success posting remain disabled.
  - [x] Add INV-10 original-provider recovery queries with append-only evidence and exactly-once verified success posting; callbacks, broad reconciliation, and reversals remain disabled.
  - [x] Add INV-11 signed replay-safe provider refund callbacks with late-success handling and exactly-once verified success posting; broad reconciliation and reversals remain disabled.
  - [x] Add INV-12 append-only provider refund reconciliation with durable mismatch exceptions and no automated financial correction.
  - [x] Add INV-13 maker-checker correction for verified post-success provider reversals with one compensating journal and preserved unit evidence.
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
  - [x] Add BS-11 acquisition/servicing feature-flag separation and fail-closed live payment/payout activation gates requiring complete provider, credential, beneficiary, webhook, settlement, reconciliation, compliance, and approval evidence.
  - [x] Add BS-12A perspective-safe customer and supplier settlement statements plus permission-gated finance reconciliation controls from payment through recovery.
  - [x] Add BS-12B durable tenant-aware booking notification events, leased in-app delivery, deterministic retries/backoff, and dead-letter evidence independent of financial state.
- [ ] Group treasury, contributions, projects, committees, meetings, voting, documents, and shared assets.
  - [x] Approve GT-01 through GT-12 group governance, contribution ownership, treasury, project, meeting, document, and shared-asset rules in [`docs/specs/GROUP_GOVERNANCE_TREASURY.md`](specs/GROUP_GOVERNANCE_TREASURY.md). Approved by the product owner on 2026-07-30.
  - [x] Add GT-01A tenant-owned group memberships and votes, multi-group eligibility, lifecycle evidence, legacy quarantine, and backend rollout flags.
  - [x] Add GT-02A immutable initial constitutions, effective-dated required offices, legacy governance review, and constitution-gated group activation.
  - [x] Add GT-02B1 tenant-bound hashed, expiring, single-use membership invitations and applicant-state evidence.
  - [x] Add GT-03A tenant-bound proposals, immutable eligible-voter and conflict snapshots, append-only ballots, deterministic thresholds, cancellation, and evidenced decisions.
  - [x] Add GT-02B2 versioned entry requirements, proposal-backed applicant admission, verified payment-gated activation, fee allocation journals, and reversal-safe membership servicing.
  - [x] Add GT-02C noticed, proposal-backed suspension and expulsion, independent appeal servicing, immutable evidence, and remove legacy direct discipline paths.
  - [x] Add GT-02D proposal-executed office appointments/removals, explicit terms and incompatibilities, bounded temporary delegations, expiry servicing, vacancies, and immutable office history.
  - [x] Add GT-04A classified contribution products with CHECK-derived economic ownership, proposal-executed versioned rules, disclosed member-attributed withdrawal and loss terms, verified payment-gated allocation to class-specific accounts, and reversal-safe contribution evidence.
  - [x] Add GT-05A dated contribution cycles pinned to one immutable rule version, per-member obligations generated from the opening eligibility snapshot, evidenced adjustments that preserve the original amount, excess parked for explicit disposition, journal-derived dashboards, and accounting-period-gated immutable close.
  - [x] Add GT-06A budget-capped internal disbursements with journal-derived available funds, atomic approve-and-reserve, enforced maker/checker/beneficiary separation backed by a chair approval permission, disclosed low-value bands recorded whole, execution that revalidates the approval snapshot, and exactly-once reservation consume or release.
  - [x] Add GT-06B1 external provider disbursements against a maker–checker verified off-platform beneficiary registry, an NGN-only inherited settlement ceiling, deferred Option-B posting that commits at begin and posts only on confirmed provider success, exactly-once reservation consume on success or release on failure, and provider timeout reconciliation that records a late success as a non-repaying exception.
  - [x] Add GT-06B2 disclosed emergency expenditure with mandatory post-hoc ratification.
  - [x] Add GT-07A journal-derived group treasury statements with cutoff reservations and aggregate ownership classification.
  - [x] Add GT-08A governed group project drafts, immutable initial budgets, proposal binding, independent approval, and activation without financial posting.
  - [x] Add GT-08B1 proposal-bound project budget amendments with immutable version retention and independent approval.
  - [x] Add GT-08B2 reasoned, tenant-governed project pause and resume transitions with append-only evidence.
  - [x] Add GT-08B3 evidence-bound project completion with deliverables, residual-fund disposition, assets, and final reconciliation.
  - [x] Add GT-08B4 proposal-authorized project closeout after completion evidence, residual disposition, and budget finality.
  - [x] Add GT-08B5 active-project, approved-budget, cumulative-cap, and restricted-fund guards to project treasury requests.
  - [x] Add GT-09 proposal-executed committee mandates traceable to the authorizing vote, effective-dated committee membership with a single sitting chair, notice-validated meetings with snapshot-based quorum, attendance records that confer no approval, and immutable approved minutes corrected only by linked addenda.
  - [x] Add GT-10A tenant-scoped group document metadata, governed publication, immutable approved versions, linked corrections, and append-only evidence.
  - [x] Add GT-10B permission-checked, rate-limited document download URLs with short expiry and immutable access evidence.
  - [x] Add GT-10C tenant-scoped shared-asset registration with governed custody, lifecycle metadata, idempotency, and immutable acquisition evidence.
  - [x] Add GT-10D non-overlapping confirmed shared-asset reservations with auditable check-out and check-in custody evidence.
  - [x] Add GT-10E manager-controlled damage reporting and maintenance servicing with immutable before/after condition evidence and reservation-aware availability guards.
  - [x] Add GT-10F manager-controlled loss reporting for uncommitted assets with immutable lifecycle, condition, custody, location, and evidence snapshots.
  - [x] Add GT-10G requester-or-manager reservation cancellation with immutable evidence, idempotency, custody-state guards, and availability recomputation.
  - [x] Add GT-10H atomic checked-out custody-loss resolution with linked reservation and asset lifecycle evidence after pending bookings are cancelled.
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
