# Investment product governance

INV-01 governs investment product facts before any customer money can move. Product creation and compliance approval are disabled by default and require `financial.investments.configure`.

Each approved version pins the issuer/operator, underlying project, funding and subscription limits, offer window, unit method, fees, expected-return warning, loss allocation, reporting schedule, maturity, exit rules, jurisdiction eligibility, risk disclosure hash, and conflicts disclosure.

The maker cannot approve their own version. Product, version, and event evidence is engine-managed and service clients receive read-only access.

INV-02 accepts a disclosure-bound subscription intent only when the product version is approved, the offer is open, the integer minor-unit amount is within the approved limits, and the investor country and type are eligible. The intent pins the exact approved product version and risk-disclosure version/hash. Replaying the same tenant idempotency key and facts returns the same immutable evidence; changed facts are rejected.

Every new intent remains `pending`. Creating it does not reserve or settle cash, post a journal, allocate units or ownership, value assets, process redemptions, distribute returns, or support secondary trading. Those workflows require separate migrations, ledger mappings, reconciliation, and tests. Disabling `financial.investments.subscribe` stops new intents without hiding existing evidence.

INV-03 requires a governed `approved` to `open` transition before any subscription intent is accepted. A finance-configure actor may open only the approved version and only within its pinned offer window. The transition is idempotent, audited, and immutable; approval alone never exposes the offer.

INV-04 binds a pending subscription to one existing posted or reconciled provider settlement of the exact tenant, currency, and gross amount. It reuses the provider settlement journal and creates immutable servicing evidence; it does not post cash again, allocate units, value the investment, or mark the product funded.

Rollback before approval means disabling `financial.investments.configure`; approved evidence remains readable. For INV-02, disable `financial.investments.subscribe` first. The subscription-intent table may be removed only if no durable intent exists; otherwise preserve it and use a forward corrective migration. Schema rollback must preserve exported product versions, disclosures, intents, events, and audit records.
