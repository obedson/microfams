# Version 1 Release Readiness

## Decision

**NO-GO for Version 1 release.**

The repository contains mature database-enforced foundations for financial accounting, booking settlement, cooperative governance, and several financial products. It does not yet implement or verify the full approved Agro Operating System across farm operations, inventory, commerce, education, intelligence, institutional programmes, clients, providers, and production operations.

## Current Evidence

- The generated [V1 reconciliation report](V1_RECONCILIATION.md) is the current source for work-plan counts, evidence paths, and status. Numeric claims are not duplicated here because they become stale as stacked delivery PRs advance.
- `candidate_complete` means every automatically required layer has discoverable evidence; it does not mean accepted or release-ready. Checked rows with missing layers remain `claimed_complete_evidence_gap`.
- CI covers type checks, unit tests, clean-schema migration tests, hosted database integration, frontend/mobile checks, a browser smoke test, dependency audit, and basic secret-pattern scanning.
- Financial and governance work is concentrated in migrations and schema tests; application-layer and user-journey coverage is less complete.

These counts are navigation aids, not acceptance metrics. A row becomes complete only after a reviewer confirms specification approval, implementation, API, required clients, tests, and operational recovery evidence.

## Gate Status

| Gate | Status | Required to pass |
|---|---|---|
| Phase 0: foundation and release safety | Fail | Secret remediation and any remaining CI release-gate evidence; deterministic evidence reconciliation is enforced in CI |
| Phase 1: tenant platform kernel | Fail | End-to-end isolation, durable jobs/events, observability and correlation evidence |
| Phase 2: trust and identity | Fail | Approved NIN/KYC flow, provider contracts, privacy/replay and complete journeys |
| Phase 3: financial core | Partial | Full account servicing, limits/freezes/closures, provider certification and zero-variance reconciliation |
| Phase 4: financial products | Partial | Complete APIs/clients/E2E, valuation/redemption, escrow settlement, live-adapter evidence |
| Phase 5: booking/groups/accounting | Partial | Parent acceptance, client journeys, operational recovery and full E2E evidence |
| Phase 6: farm/assets/marketplace/education | Fail | Approved specifications and complete domain implementations |
| Phase 7: intelligence/institutional portals | Fail | Approved specifications, adapters, portals and permissioned workflows |
| Phase 8: release validation | Fail | Full test matrix, runbooks, recovery exercises and acceptance evidence |

## Completion Rule

An item may be accepted only when all applicable conditions are linked and reviewed:

```text
approved specification
AND migration/domain implementation
AND authenticated tenant-safe API
AND required web/mobile workflow
AND required test layers passing in CI
AND operational, reconciliation, disable, and recovery documentation
```

The operating and recovery procedure is documented in [V1 evidence reconciliation operations](runbooks/V1_EVIDENCE_RECONCILIATION.md).

## Next Release Milestone

The next credible milestone is **V1 backend foundation complete**, not a V1 product release. That milestone should require:

1. Reconciled Phase 0-5 evidence with no unchecked parent hiding incomplete child workflows.
2. API and feature-flag coverage for every implemented financial/governance command.
3. Full backend E2E journeys for booking, group treasury, savings, credit, investments, dividends, and escrow.
4. Provider sandbox and reconciliation certification.
5. Recovery and operational runbooks for every financial workflow.

Only after that gate should the project claim completion percentages for the farm, commerce, education, intelligence, and institutional V1 domains.
