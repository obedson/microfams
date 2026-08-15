# Investment product governance

INV-01 governs investment product facts before any customer money can move. Product creation and compliance approval are disabled by default and require `financial.investments.configure`.

Each approved version pins the issuer/operator, underlying project, funding and subscription limits, offer window, unit method, fees, expected-return warning, loss allocation, reporting schedule, maturity, exit rules, jurisdiction eligibility, risk disclosure hash, and conflicts disclosure.

The maker cannot approve their own version. Product, version, and event evidence is engine-managed and service clients receive read-only access.

INV-02 accepts a disclosure-bound subscription intent only when the product version is approved, the offer is open, the integer minor-unit amount is within the approved limits, and the investor country and type are eligible. The intent pins the exact approved product version and risk-disclosure version/hash. Replaying the same tenant idempotency key and facts returns the same immutable evidence; changed facts are rejected.

Every new intent remains `pending`. Creating it does not reserve or settle cash, post a journal, allocate units or ownership, value assets, process redemptions, distribute returns, or support secondary trading. Those workflows require separate migrations, ledger mappings, reconciliation, and tests. Disabling `financial.investments.subscribe` stops new intents without hiding existing evidence.

INV-03 requires a governed `approved` to `open` transition before any subscription intent is accepted. A finance-configure actor may open only the approved version and only within its pinned offer window. The transition is idempotent, audited, and immutable; approval alone never exposes the offer.

INV-04 binds a pending subscription to one existing posted or reconciled provider settlement of the exact tenant, currency, and gross amount. It reuses the provider settlement journal and creates immutable servicing evidence; it does not post cash again, allocate units, value the investment, or mark the product funded.

INV-05 allocates immutable units only after the approved offer window closes, the subscription is settled, the approved method is fixed unit price, the amount divides exactly by that price, and total settled subscriptions do not exceed the funding target. Oversubscription, percentage ownership, valuation, returns, transfer, and redemption remain disabled pending separate governed increments.

INV-06 creates deterministic, immutable oversubscription plans after settlement intake is finalized. Pro-rata plans use largest remainder with settlement-time and UUID tie-breaks; first-settled plans allocate in settlement order. Unallocated cash is recorded as a refund liability. Independent approval does not issue units, post journals, or execute refunds.

## Refund recovery

Use the recovery command only for existing submitted, processing, or unknown refund obligations. It queries the original provider route with the durable attempt reference. Exact verified success posts one balanced journal from investment refunds payable to provider clearing; missing, ambiguous, failed, or mismatched evidence preserves the liability.

Recovery remains available through the servicing feature when new provider submissions are disabled.

Signed refund callbacks are accepted at `/api/webhooks/paystack/investment-refunds` from exact raw JSON bytes. Callback identity is bound to the durable `investment-refund-<attempt-id>` marker, original provider and environment, exact obligation money, and a masked provider refund reference. Exact byte replay returns the stored event; reuse of a provider event ID with changed bytes is rejected. A late exact success after provider failure posts the success journal once. Money mismatches preserve the payable in manual review, and non-success evidence after success cannot reopen the obligation.

After callback evidence exists, rollback must preserve the event and any success journal; disable provider delivery and use a forward corrective migration. Broad reconciliation, post-success reversals, and live-provider activation remain separate release work.

## Refund reconciliation

INV-12 accepts an authoritative provider evidence batch and records an append-only comparison against local refund attempts. It classifies exact matches, duplicate provider evidence, missing local or provider evidence, late success after timeout or failure, and amount, currency, or status mismatches. Every non-match creates a durable open exception and preserves the refund liability.

Reconciliation never changes an obligation or attempt, posts a journal, submits a refund, or treats a provider success as final. Verified callbacks or recovery commands remain the only success-posting paths. Post-success reversals and automated financial correction remain disabled.

Rollback before approval means disabling `financial.investments.configure`; approved evidence remains readable. For INV-02, disable `financial.investments.subscribe` first. The subscription-intent table may be removed only if no durable intent exists; otherwise preserve it and use a forward corrective migration. Schema rollback must preserve exported product versions, disclosures, intents, events, and audit records.
