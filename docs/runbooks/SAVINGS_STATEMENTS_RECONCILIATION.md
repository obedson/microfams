# Savings Statements and Reconciliation

## Scope

SAV-05 provides read-only servicing controls for existing savings obligations. Member statements are derived at request time from immutable journal lines on the enrolment's principal and accrued-return liability accounts. Tenant finance reconciliation independently compares savings contribution, posted return, and settled withdrawal evidence with those journals.

Provider and live-rail certification is SAV-06. No provider credential is required for this increment.

## Feature and authorization controls

- `GET /api/savings/enrolments/:enrolmentId/statement` uses `financial.savings.read`. The member may read their own tenant enrolment; an authorized tenant finance actor with `financial.reconciliation.manual` may inspect it for control work.
- `GET /api/savings/reconciliation` uses `financial.savings.service_existing` and requires `financial.reconciliation.manual`.
- Contribution, enrolment, accrual, withdrawal, and product-configuration flags may be disabled without disabling these servicing reads.
- Both database functions bind every lookup to `organization_id`; an unrelated tenant or user receives no statement or reconciliation data.

## Statement contract

The caller supplies an optional date range, reproducibility cutoff, page, and page size. The response contains:

- principal, accrued-return, and combined opening/closing balances;
- a page opening balance so running balances remain correct across pagination;
- chronological journal entries with signed movements and running component balances;
- contribution method, accrual formula/period, or withdrawal fee/forfeiture evidence when applicable;
- string-encoded minor-unit amounts to avoid JavaScript precision loss.

The statement does not read a mutable savings balance. Corrections and reversals therefore remain visible through their journal evidence.

## Reconciliation contract

Reconciliation is currency-specific and reproducible at a supplied cutoff. For each enrolment it compares:

- contribution evidence against savings-principal journal credits;
- approved accrual items against accrued-return journal credits;
- settled withdrawal allocations against principal/return journal debits;
- the resulting expected liabilities against journal-derived liabilities.

Issues are classified as `unmatched`, `duplicate`, `amount_mismatch`, or `late`; an enrolment with no issue is `matched`. Pending withdrawals are reported as reservations and do not reduce the posted liability. A configurable 1–720 hour threshold identifies stale pending withdrawals, pending accrual approval, and interrupted standing-order attempts.

## Incident response

A non-zero `unexplainedVarianceMinor` or any unmatched, duplicate, or amount-mismatch item is a finance incident:

1. Disable flags that create new savings exposure for the affected tenant; keep read and servicing flags enabled.
2. Record the cutoff, currency, enrolment, journal IDs, correlation IDs, and source evidence from the response.
3. Do not edit savings evidence or posted journals. Investigate the original command, worker, and accounting evidence.
4. Correct confirmed errors only through an approved reversal or compensating journal workflow.
5. Re-run reconciliation at a new cutoff and retain both results as incident evidence.

Late items require worker/approval investigation. They do not authorize automatic settlement or balance mutation.

## Recovery and rollback

The migration adds only `SECURITY DEFINER` read functions and grants them exclusively to `service_role`; it does not create or mutate savings records. Application rollback removes the two API routes and gateway calls. Database rollback may revoke and drop the two functions after confirming no deployed application version calls them. Existing savings data and journals are unaffected.
