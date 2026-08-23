# Accounting Income Statement Operations

AC-02 reads revenue and expense movements exclusively from posted journal entries for one organisation, currency, accounting-period-contained date range, and explicit cutoff. Operators require `financial.accounting.read`; the backend feature flag and database permission both fail closed.

Record the organisation, actor, currency, dates, cutoff, accounting period, totals, and request correlation ID. Confirm total revenue less total expense equals net income and reproduce the request with the same cutoff during investigation.

Invalid dates, future cutoffs, cross-period ranges, permission failures, and database errors return no partial statement. Do not repair reports by editing journal entries or balances. Correct source accounting through reversals or compensating postings, then rerun with a new cutoff. Disable `financial.accounting.read` to stop new reads without hiding existing journal evidence.
