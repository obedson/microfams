# Version 1 Gaps

This report interprets the evidence matrix in [V1_RECONCILIATION.md](V1_RECONCILIATION.md). It is deliberately stricter than the checkboxes in `WORK_PLAN.md`: schema or code presence alone does not establish a complete V1 capability.

## Release-Blocking Gaps

### Foundation and platform kernel

- Complete secret rotation and repository-history remediation evidence.
- Finish typed runtime configuration validation and a maintained secret inventory.
- Prove tenant isolation across database reads/writes, APIs, exports, analytics, jobs, and aggregate reports.
- Add durable cross-domain outbox/job infrastructure or explicitly document the approved substitute for each asynchronous workflow.
- Complete metrics, tracing, health checks, correlation propagation, and operational alerting.
- Publish architecture decisions, API conventions, and stable error-envelope rules.

### Trust and identity

- Approve one authoritative NIN ownership and consent flow.
- Demonstrate provider-neutral KYC retry, replay, redaction, retention, and degraded-provider behavior.
- Complete organization verification and any approved BVN/face-verification scope.
- Join review, suspension, appeal, legal hold, retention, and recovery into tested end-to-end user and operator journeys.

### Financial core and products

- Reconcile schema engines with public API routes and permission/feature-flag enforcement for every product command.
- Add web/mobile servicing journeys for savings, credit, investments, dividends, and escrow where required by the approved product scope.
- Finish investment valuation, maturity/redemption, and ordinary (non-oversubscription) servicing.
- Finish external dividend payout or formally constrain V1 to internal wallets in an approved specification.
- Finish escrow dispute allocation settlement/refund execution and reconciliation.
- Demonstrate provider sandbox certification and zero unexplained reconciliation variance for every live money rail.
- Complete limits, freezes, closures, incident recovery, and journal-derived statements for all required account families.

### Farm operating system

- Specify and implement farms/plots, crop cycles, livestock, calendars, tasks, workers, attendance, inputs, expenses, yields, evidence, and offline synchronization as cohesive domains.
- Replace legacy farm-record CRUD with tested operational workflows and tenant isolation.

### Inventory, marketplace, and education

- Implement warehouses, stock movements, equipment maintenance, utilization, depreciation metadata, and internal booking.
- Complete marketplace services, delivery, escrow settlement, returns, ratings, and disputes.
- Complete learning paths, assessments, certificates, extension-officer workflows, group learning, and offline content.

### Intelligence and institutional portals

- Add provider-neutral weather, mapping, and satellite contracts with deterministic and sandbox adapters.
- Add source-attributed agronomic recommendations with provenance and confidence.
- Add a permission-scoped, audited AI assistant with citations and human confirmation for actions.
- Implement NGO/government programmes, cohorts, interventions, benefits, monitoring, outcomes, dashboards, and exports.

### Release validation and operations

- Implement the thirteen critical journeys listed in `docs/TEST_STRATEGY.md`; one smoke file is not sufficient.
- Add accessibility, performance, load/concurrency, backup/restore, migration recovery, and provider-degradation test gates.
- Test feature flags when enabled, disabled, missing, misconfigured, and servicing existing records.
- Publish incident response, backup/restore, rollback, reconciliation, support, and deployment runbooks.
- Produce a release-candidate acceptance package with linked CI runs and product-owner sign-off.

## Reconciliation Priorities

1. Review every `claimed_complete_evidence_gap` row and either add evidence, narrow the work-plan claim, or reopen the task.
2. Review every `candidate_complete` row manually; automated discovery cannot establish behavioral correctness or formal approval.
3. Add stable identifiers to all parent work-plan items so parent completion can be derived from children.
4. Make API, client, testing, and operations evidence explicit in pull-request templates and future work-plan updates.
5. Re-run `node scripts/reconcile-v1.mjs` whenever the work plan or evidence files change.
