# Accounting budget-versus-actual operations

The report is tenant scoped and protected by the `financial.accounting.read` feature and permission gates. It selects the latest approved immutable budget version visible at the requested cutoff and compares it with posted journal actuals for the same accounting period.

Record currency, dates, and UTC cutoff for every export. Do not edit budget rows or journal entries manually. Disable new report requests with the accounting-read feature flag; recover data issues through approved immutable budget versions or compensating journal postings, then rerun using the original cutoff.
