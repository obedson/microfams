# Financial modules approval and release operations

## Scope

This runbook is the operational evidence for the approved cross-product financial rules in `docs/specs/FINANCIAL_MODULES_APPROVAL_SPEC.md`. It covers wallets, payments, escrow, savings, investments, loans/credit, dividends, and cooperative accounting.

The specification was approved by the product owner on 2026-08-09. Approval authorizes the rules; it does not enable live financial exposure or bypass provider, compliance, authorization, reconciliation, or feature-flag gates.

## Approval register

Retain the approval record with the reviewed specification commit, approver identity, approval date, jurisdiction, provider/environment, compliance owner, and any amended decisions. The register must cover integer minor-unit money, balanced immutable journals, tenant isolation, idempotency, maker-checker controls, provider callback verification, reconciliation, servicing-safe disablement, and the approved product lifecycle rules.

## Activation evidence

Before enabling any acquisition flag, verify the applicable product specification, migration, API authorization, client disclosure, unit/integration/API/E2E tests, provider certification, reconciliation sign-off, limits, support owner, and rollback plan. Record the feature-flag decision, tenant, environment, correlation ID, approval evidence reference, and effective time.

Deterministic and sandbox modes must remain visibly distinct from live mode. Missing credentials, compliance metadata, provider configuration, reconciliation certification, or approval evidence fail closed with no synthetic success.

## Disablement and rollback

To roll back an activation, disable the product acquisition flag and provider-live flag while retaining read access, callbacks, reconciliation, refunds, reversals, statements, and servicing of existing obligations. Do not delete or rewrite posted journals, immutable approvals, provider evidence, or tenant records. Corrective changes use a reviewed forward migration and compensating journals where required.

After live financial activity exists, schema rollback is prohibited. Re-enable acquisition only after the approval register, provider certification, reconciliation, and zero-unexplained-variance evidence are renewed.

## Verification

Run from the Codespace:

```bash
npm --prefix backend run typecheck
npm --prefix backend run test:unit
npm --prefix backend run test:schema
node scripts/reconcile-v1.mjs --check
```
