# Accounting Balance Sheet Operations

AC-03 reads posted journal movements for one tenant, currency, accounting period, and explicit cutoff. The backend requires `financial.accounting.read`, and the database validates the accounting equation before returning results.

Capture the organisation, actor, date range, cutoff, period, totals, and correlation ID. Confirm assets equal liabilities plus equity plus current-period earnings. A future cutoff, cross-period range, permission failure, or imbalance returns no partial report.

Do not edit journal entries, balances, or report rows to correct an imbalance. Investigate source postings and use approved reversals or compensating journals, then rerun with a new cutoff. Disable `financial.accounting.read` to stop new reads while preserving historical evidence.
