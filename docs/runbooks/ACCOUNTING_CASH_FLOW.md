# Accounting cash-flow operations

The AC-04 report is read-only, tenant scoped, and protected by the backend `financial.accounting.read` feature and permission gates. Operators must record the requested currency, reporting dates, and UTC cutoff when reproducing a report.

The report is derived only from posted journal entries and the canonical `operating_cash` account purpose. Operating, investing, financing, and unclassified totals must reconcile to the net cash change. Any unclassified amount requires accounting review of the source-domain mapping; it must not be silently reassigned.

To disable new requests, turn off the tenant/environment accounting-read feature flag. Existing journals remain available and unchanged. If the API or client causes an incident, roll back the application release; the migration remains safe because it only installs a security-definer read function whose execution is restricted to the service role. Recovery consists of correcting journal entries through compensating postings or updating approved classification rules, then rerunning at the original cutoff.
