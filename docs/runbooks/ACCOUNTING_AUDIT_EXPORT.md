# Accounting Journal Audit Export Operations

This runbook covers AC-07 tenant-scoped, cutoff-reproducible journal audit exports. The export is a read-only evidence view; it never changes journals, balances, accounting periods, or reconciliation state.

## Request checklist

1. Confirm the actor has `financial.accounting.read` in the target organization and that the organization context is resolved from authenticated membership.
2. Select an ISO currency, inclusive date range, and UTC cutoff timestamp no later than the current database time. The requested range must be fully contained in an accounting period.
3. Invoke the trusted backend `read_accounting_audit_export` command. Direct client execution and direct table reads are prohibited.
4. Record the export request reference, organization, currency, date range, cutoff, entry count, line count, and correlation ID. Preserve the returned journal entry and line evidence according to the organization retention policy.
5. Re-run with the same cutoff when reproducing a report. Do not compare a moving current-time export with a prior snapshot and call the difference a variance.

## Review controls

Verify that every exported entry is tenant-scoped, posted before the cutoff, within the selected period and date range, and includes its source domain, source record, idempotency key, correlation ID, actor, and ordered journal lines. Confirm debit and credit totals using the journal invariant before sharing the export with an auditor or institution.

Exports may contain financial identifiers and actor metadata. Restrict downloads to authorized finance personnel, use encrypted approved storage, and do not place provider secrets, identity numbers, or raw payment credentials in filenames or notes.

## Failure and recovery

- `ACCOUNTING_AUDIT_EXPORT_PERMISSION_DENIED`: verify organization membership and the `financial.accounting.read` permission; do not broaden access to make the export work.
- `ACCOUNTING_AUDIT_EXPORT_PERIOD_REQUIRED`: select an accounting period that contains the entire requested range; do not bypass period controls.
- `ACCOUNTING_AUDIT_EXPORT_REQUEST_INVALID`: correct currency, dates, or cutoff; never substitute a future cutoff.
- Database or provider unavailability: retry the same request after service recovery. The command is read-only and has no financial rollback.

If an export is suspected to be incomplete or mis-scoped, quarantine it, preserve the request parameters and correlation ID, and rerun from the same cutoff after the incident is resolved. Never edit journal evidence to reconcile an export discrepancy.

## Monitoring evidence

Track denied requests, invalid period/cutoff requests, export latency, entry/line counts, and repeated reruns. Investigate any export whose journal totals are unbalanced, whose tenant scope differs from the request, or whose returned evidence changes for the same cutoff.