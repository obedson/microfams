# Investment product governance

INV-01 governs investment product facts before any customer money can move. Product creation and compliance approval are disabled by default and require `financial.investments.configure`.

Each approved version pins the issuer/operator, underlying project, funding and subscription limits, offer window, unit method, fees, expected-return warning, loss allocation, reporting schedule, maturity, exit rules, jurisdiction eligibility, risk disclosure hash, and conflicts disclosure.

The maker cannot approve their own version. Product, version, and event evidence is engine-managed and service clients receive read-only access.

This slice does not accept subscriptions, reserve or settle cash, allocate units, value assets, process redemptions, distribute returns, or support secondary trading. Those workflows require separate migrations, ledger mappings, reconciliation, and tests.

Rollback before approval means disabling `financial.investments.configure`; approved evidence remains readable. Schema rollback must preserve exported product versions, disclosures, events, and audit records.
