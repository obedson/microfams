# Micro Fams V1 Financial Core Specification

Status: proposed for product-owner approval. No financial-core implementation may rely on this document until its status is changed to `approved` with an approval record.

## Purpose

This specification defines the accounting, money, wallet, payment, payout, settlement, fee, refund, reversal, and reconciliation rules that every Micro Fams Version 1 financial product must use. It establishes the financial source of truth before savings, credit, investments, escrow, dividends, cooperative accounting, and real-money provider workflows are implemented.

The financial core is tenant-isolated and provider-neutral. Feature flags control whether new exposure can be created, but they never weaken accounting, authorization, licensing, identity, reconciliation, or servicing obligations.

## Authority and conflict resolution

When approved, this specification supersedes conflicting financial implementation details in `.kiro/specs/group-individual-wallet-system/`, including:

- treating `wallet_transactions` as an accounting ledger;
- treating wallet or group balance columns as the source of truth;
- storing money as floating-point values or undocumented decimal major units;
- one global user wallet instead of organization-scoped accounts;
- hard-coded transaction limits described as permanent regulatory limits;
- successful single-sided balance records for transfers; and
- provider success without an idempotent balanced journal and reconciliation path.

The wallet specification's user journeys remain product requirements where they do not conflict with this document. Each financial product must later provide its own approved rules and ledger mappings.

## Normative language

`MUST`, `MUST NOT`, `SHOULD`, and `MAY` are normative. A requirement marked `proposed decision` requires explicit approval in the approval record.

## 1. Tenant and legal-entity boundary

1. Every financial account, journal, payment, payout, wallet, reconciliation item, limit, approval, and statement MUST carry `organization_id`.
2. An organization is the operational accounting boundary. Records MUST NOT be posted across organizations in one journal entry.
3. A person, group, programme, or farm may have accounts in multiple organizations; each relationship is isolated.
4. Platform operator accounts MUST be explicit and separate from tenant accounts. Platform-admin access MUST NOT imply ownership of tenant funds.
5. Cross-organization settlement or platform fees MUST use explicit due-to/due-from or clearing accounts in separate balanced entries linked by one correlation identifier.

## 2. Money representation

Proposed decision FC-01:

1. Application and database money amounts MUST use signed 64-bit integer minor units. For NGN, `100` represents ?1.00.
2. APIs MUST expose amounts as integer minor units plus an ISO 4217 currency code. They MUST NOT accept JavaScript floating-point money.
3. Every financial account MUST have exactly one currency. A journal entry MUST contain lines in one currency only.
4. Version 1 financial core MUST NOT perform foreign-exchange conversion. Multi-currency accounts MAY exist, but conversion requires a separately approved FX specification.
5. Percentage rates MUST use documented fixed precision, expressed as integer basis points or a fixed-scale decimal. Calculations MUST define rounding explicitly.
6. Division MUST use round-half-up to the currency minor unit unless a product specification requires a different disclosed rule. Residual minor units MUST be allocated deterministically and recorded.
7. Database constraints MUST reject zero-value journal lines, unbalanced entries, invalid currencies, and values outside the supported integer range.

## 3. Account model and chart of accounts

Proposed decision FC-02:

1. The financial source of truth MUST consist of first-class ledger accounts, journal entries, and journal lines.
2. Account classes are `asset`, `liability`, `equity`, `revenue`, and `expense`.
3. Accounts MUST have stable codes, names, currency, organization, owner type, owner identifier where applicable, status, normal balance, control-account marker, and effective dates.
4. Account ownership types MUST include at least `organization`, `user`, `group`, `provider`, `escrow_contract`, `savings_contract`, `loan_contract`, `investment_contract`, and `system`.
5. Control accounts MUST reconcile to their subledgers. A wallet balance is a subledger view of the corresponding customer-funds liability account.
6. Accounts with posted activity MUST NOT be deleted or repurposed. They MAY be frozen or closed after their balance is zero and obligations are resolved.
7. Chart templates MAY be copied into an organization, but account identifiers and balances remain tenant-specific.

Minimum control accounts:

| Class | Account purpose |
| --- | --- |
| Asset | Operating bank cash |
| Asset | Provider clearing by provider and currency |
| Asset | Settlement receivable |
| Asset | Loan principal receivable |
| Liability | Individual wallet funds |
| Liability | Group wallet funds |
| Liability | Pending payout |
| Liability | Escrow funds held |
| Liability | Savings principal and accrued return |
| Liability | Investor subscriptions/redemptions payable |
| Liability | Dividends payable |
| Revenue | Platform fees by type |
| Expense | Provider processing fees |
| Expense | Credit loss and write-off |
| Equity | Opening balance and retained surplus |

## 4. Journal lifecycle and invariants

Proposed decision FC-03:

1. Journal entry states are `draft`, `posted`, and `reversed`.
2. Draft entries have no financial effect. A posted entry is immutable.
3. Every posted entry MUST contain at least two lines and total debits MUST equal total credits in the same currency.
4. Every posted entry MUST include `organization_id`, currency, effective date, source domain, source record, idempotency key, correlation identifier, description, actor or system identity, and timestamps.
5. The tuple `(organization_id, source_domain, idempotency_key)` MUST be unique.
6. Journal posting and the related domain-state transition MUST occur in one database transaction or through an atomic posting command that is safely recoverable.
7. Corrections MUST use a complete reversal linked to the original entry, followed by a corrected entry when required. Lines and posted metadata MUST NOT be edited or deleted.
8. A reversal MUST use the original amounts with debit and credit sides exchanged. Reversing an entry twice MUST be rejected.
9. Back-dated posting MUST require an open accounting period and an authorized role. Closed periods MUST reject new or changed postings.
10. Balance snapshots are rebuildable caches. The posted journal is authoritative.

## 5. Available, pending, and ledger balances

Proposed decision FC-04:

1. Each wallet or financial contract MUST distinguish `ledger_balance`, `pending_debits`, `pending_credits`, and `available_balance`.
2. `available_balance = ledger_balance - reserved_or_pending_debits`, subject to product-specific holds.
3. A new withdrawal, redemption, escrow commitment, or disbursement MUST reserve available funds before an external call.
4. A reservation MUST have an expiry, state, idempotency key, and linked release/consume action.
5. Disabling new transactions MUST NOT prevent release of expired holds, reversals, refunds, reconciliation, statements, or servicing of existing obligations.

## 6. Canonical posting templates

The exact account identifiers are tenant-specific, but approved products MUST map economic events to these patterns.

| Economic event | Debit | Credit |
| --- | --- | --- |
| Confirmed inbound wallet funding | Provider clearing asset | Individual or group wallet liability |
| Internal wallet transfer | Sender wallet liability | Recipient wallet liability |
| Withdrawal reserved | Individual/group wallet liability | Pending payout liability |
| Payout succeeds | Pending payout liability | Provider clearing or bank cash asset |
| Payout fails or is reversed | Pending payout liability | Original wallet liability |
| Gross provider settlement | Bank cash asset | Provider clearing asset |
| Provider fee withheld | Provider fee expense | Provider clearing asset |
| Platform fee charged to customer funds | Customer/product liability | Platform fee revenue |
| Escrow funded | Funding wallet liability | Escrow funds-held liability |
| Escrow released | Escrow funds-held liability | Beneficiary wallet or payout liability |

1. Initiating an external payment without confirmed value MUST NOT recognize cash or revenue.
2. Provider confirmation is a financial input, not sufficient proof by itself; it MUST pass signature verification, idempotency, amount, currency, tenant, and reference validation.
3. Product-specific revenue recognition, interest, returns, penalties, loss provisions, taxes, and withholding require their own approved mappings.

## 7. Payment and payout orchestration

Proposed decision FC-05:

1. Provider-neutral commands MUST use adapters; controllers and domain services MUST NOT depend directly on Paystack or Interswitch payloads.
2. Payment states are at least `created`, `requires_action`, `processing`, `succeeded`, `failed`, `cancelled`, `expired`, `partially_refunded`, and `refunded`.
3. Payout states are at least `created`, `reserved`, `submitted`, `processing`, `succeeded`, `failed`, `reversed`, and `cancelled`.
4. State transitions MUST be allowlisted and monotonic except for explicit provider reversal states.
5. Every initialization, confirmation, webhook, status query, refund, reversal, and retry MUST be idempotent.
6. The system MUST store its own immutable internal reference and separately store provider references. Provider references MUST be unique within provider and environment.
7. Amount, currency, customer/beneficiary, provider account, and tenant MUST be verified before a callback can change state or post a journal.
8. Synchronous provider timeouts MUST leave a recoverable `processing` state. They MUST NOT be reported as success or immediately retried with a new financial reference.
9. Provider webhook ingestion MUST preserve the verified raw-event hash and receipt time, acknowledge within provider requirements, and process through a recoverable job.
10. Sandbox, deterministic test, and live adapters MUST satisfy the same contract. A missing live provider MUST return a configuration error, never a fake success.

## 8. Fees, refunds, reversals, and disputes

1. Fees MUST be represented independently from principal and MUST identify payer, beneficiary, calculation rule, tax metadata, and journal entry.
2. A fee preview MUST be bound to the actor, tenant, amount, currency, destination, rule version, and a short expiry. Confirmation MUST reject changed or expired previews.
3. Refunds MUST support full and partial amounts, cumulative-refund limits, idempotency, reason codes, approvals, provider state, and journal linkage.
4. A provider reversal MUST not mutate the original payment. It MUST create a linked reversal domain record and compensating journal.
5. Disputes and chargebacks MUST preserve contested, recoverable, recovered, and loss amounts separately.
6. Provider fees that are non-refundable MUST remain expenses unless an explicit provider recovery is confirmed.

## 9. Reconciliation and settlement

Proposed decision FC-06:

1. Each external provider and bank account MUST have a reconciliation configuration per environment and currency.
2. Reconciliation MUST compare internal payment/payout records, posted journal entries, provider transactions, provider settlements, fees, and bank settlement totals.
3. Reconciliation states are `unmatched`, `matched`, `mismatch`, `duplicate`, `late`, `investigating`, and `resolved`.
4. Matching MUST use provider reference, internal reference, amount, currency, direction, and an approved date window. Amount-only matching is forbidden.
5. Reconciliation imports and webhook events MUST be idempotent and retain an immutable source-file or event hash.
6. Differences MUST enter an exception queue. Resolution requires a reason, actor, evidence, and any compensating journal.
7. A daily close MUST report opening balance, movements, closing balance, provider/bank balance, matched value, and unexplained variance.
8. Production financial exposure MUST NOT be enabled until deterministic reconciliation tests demonstrate zero unexplained variance for the adapter's certification scenarios.

## 10. Limits, KYC, risk, and configurable rules

Proposed decision FC-07:

1. Transaction and balance limits MUST be stored as effective-dated, tenant-, jurisdiction-, product-, channel-, currency-, and KYC-tier-aware rules.
2. The platform MAY impose a lower product or user limit than a provider/regulatory ceiling. It MUST NOT exceed an applicable ceiling.
3. Limits MUST support per-transaction, rolling-period, calendar-day, balance, velocity, beneficiary, and aggregate dimensions.
4. The historical ?50,000 P2P and ?100,000 withdrawal values MUST become configurable test defaults only; they MUST NOT be labelled as current legal limits without compliance approval.
5. A compliance snapshot identifier and rule version MUST be recorded on every approved financial command.
6. Individual Tier 1 wallet activation MUST require electronically validated BVN or NIN according to the applicable provider and regulatory programme. Higher tiers or provider contracts MAY require both.
7. Live activation MUST record the licensed provider/partner, responsible compliance owner, approval evidence, jurisdiction, KYC rules, and effective regulatory source date.
8. Risk holds, freezes, sanctions/watch-list outcomes, and manual review MUST block new exposure while still allowing legally required servicing and corrections.

Primary regulatory references to review at each live activation:

- [CBN Circular on Tier 1 Wallets and Accounts, 1 December 2023](https://www.cbn.gov.ng/Out/2023/PSMD/Circular%20on%20Tier%201%20Wallets%20%26%20Accounts%2C%20Guidance%20Note%20%26%20Profiling%20of%20Customers%27%20Accounts%20%26%20Wallets.pdf)
- [CBN BVN regulatory overview](https://www.cbn.gov.ng/PaymentsSystem/BVN.html)
- [CBN reforms and current payment-system initiatives](https://www.cbn.gov.ng/AboutCBN/Reforms.html)

These links are evidence inputs, not a substitute for legal/compliance approval or provider certification.

## 11. Authorization and approvals

1. Roles are organization-scoped. Global platform administration MUST NOT grant silent access to post tenant journals or move tenant funds.
2. Read roles MAY include owner, admin, finance manager, auditor, and explicitly permitted programme roles.
3. Posting, refunds, payouts, manual reconciliation, account freezes, period close, and rule changes require separate permissions.
4. Manual adjustments, live-provider activation, regulated feature overrides, limit increases, reconciliation write-offs, and period reopen MUST use maker-checker approval. One actor MUST NOT perform both actions.
5. Group withdrawal thresholds belong to the group-treasury product specification. The existing two-thirds rule remains proposed and MUST NOT be embedded in the core ledger.
6. Every denied and approved sensitive command MUST be auditable without logging secrets or full bank/identity data.

## 12. Feature flags and live activation

The backend MUST enforce the existing acquisition/servicing pairs:

- `financial.payments.accept_new` / `financial.payments.service_existing`;
- `financial.payouts.create` / `financial.payouts.service_existing`;
- `financial.wallets.transact` / `financial.wallets.read`;
- `financial.accounting.post` / `financial.accounting.read`; and
- the corresponding escrow, savings, investment, loan, and dividend pairs.

1. Acquisition flags fail closed. Existing-obligation servicing follows the approved safe-failure policy.
2. Live routing additionally requires the provider live flag, validated credentials, webhook secret, provider account configuration, approval metadata, and successful reconciliation certification.
3. Deterministic and sandbox modes MUST be explicitly identified in records and UI. Test money MUST never be represented as live money.
4. Emergency disablement MUST record reason, actor, incident, and time. It MUST preserve inbound callbacks and recovery records even when posting is paused for manual review.

## 13. Privacy, security, and audit

1. Bank account numbers, BVN/NIN values, provider tokens, signatures, OTPs, and raw identity evidence MUST NOT appear in journal descriptions, general metadata, logs, analytics, or client-visible errors.
2. Sensitive destination data MUST be encrypted at rest where retained and returned masked by default.
3. Webhook verification MUST use the raw payload, constant-time signature comparison, provider replay protection where available, and an internal event-hash uniqueness constraint.
4. Financial commands MUST carry correlation IDs and produce structured audit events containing actor, tenant, action, resource, outcome, rule version, and reason where applicable.
5. Audit records and posted journals MUST be immutable and retained according to an approved retention schedule.

## 14. Statements and accounting outputs

1. Customer and group statements MUST be derived from posted journals and linked domain descriptions, not mutable balance-history rows.
2. Organization accounting MUST support an effective-dated chart of accounts, fiscal periods, journals, general ledger, trial balance, income statement, balance sheet, and auditable exports.
3. Statement opening plus posted movements MUST equal closing balance for every account and currency.
4. Reports and exports MUST be tenant-scoped, permission-checked, reproducible for a cutoff time, and protected against spreadsheet formula injection.
5. Period close MUST verify balanced journals, subledger/control-account reconciliation, settlement reconciliation, and zero unexplained variance or an explicitly approved exception.

## 15. Migration from the current wallet model

Proposed decision FC-08:

1. Existing `NUMERIC(15,2)` money MUST be converted to integer minor units through an audited migration that rejects fractions below one minor unit and out-of-range values.
2. Existing organization ownership MUST be complete before financial migration. Quarantined or ambiguous records MUST NOT be silently assigned to an active tenant.
3. Opening balances MUST be posted as balanced migration journals against a dedicated opening-balance equity or migration-clearing account.
4. Existing `wallet_transactions` MUST be retained as legacy evidence and linked to migration journals where trustworthy. They MUST not become journal lines directly without validation.
5. `user_wallets.balance` and `groups.group_fund_balance` become derived caches after cutover. Writes outside the posting engine MUST be denied.
6. Migration MUST include pre/post counts, amount control totals by tenant and currency, duplicate-reference analysis, orphan analysis, rollback steps, and a signed exception report.
7. Cutover MUST support a read-only financial mode, dry run, repeatable reconciliation, and rollback before live posting is enabled.

## 16. Required data and application boundaries

The implementation is expected to introduce bounded financial-core structures equivalent to:

- `financial_accounts`;
- `accounting_periods`;
- `journal_entries` and `journal_lines`;
- `balance_snapshots` or rebuildable account balances;
- `fund_reservations`;
- provider-neutral `payment_attempts`, `payouts`, and `provider_events`;
- `settlements`, `reconciliation_runs`, `reconciliation_items`, and `reconciliation_exceptions`;
- `financial_rule_sets` and rule versions; and
- immutable financial audit/domain-event records.

Business logic MUST live in financial domain services and atomic database posting commands. Controllers, cron jobs, React components, and provider adapters MUST not construct ledger lines independently.

## 17. Test and release acceptance criteria

Implementation is not complete until CI proves:

1. unit tests for money, rounding, state transitions, posting templates, limits, and approval rules;
2. property tests that every generated posted entry balances and duplicate idempotency keys never double-post;
3. database integration tests for concurrent debit/reservation attempts, immutable postings, reversals, tenant isolation, period locks, and rollback;
4. API tests for authentication, tenant roles, validation, flags, idempotency, masked data, and provider misconfiguration;
5. adapter contract tests for deterministic, sandbox, live-shaped callbacks, signature failures, replay, timeouts, duplicates, late success, and reversals;
6. reconciliation tests for exact matches, net settlement fees, duplicates, missing events, partial refunds, reversals, and zero unexplained variance;
7. component and end-to-end tests for balances, statements, fee preview, confirmation, pending/degraded states, approvals, refunds, and disabled flags;
8. migration tests on clean and representative legacy schemas with control totals; and
9. security, audit, dependency, recovery, and performance gates.

## 18. Product specifications still required for Version 1

Approval of this core does not silently approve product economics. Separate specifications are required for:

- savings products, accrual/interest, goals, standing orders, and early withdrawal;
- credit eligibility, underwriting, schedules, delinquency, restructuring, and write-off;
- investments, unitization, valuation, subscriptions, redemptions, and disclosures;
- escrow conditions, disputes, partial release, expiry, and unclaimed funds;
- dividends/profit sharing, eligibility dates, allocation, withholding, approvals, and payment;
- group treasury contribution ownership, voting thresholds, penalties, and member exits; and
- booking/marketplace escrow, refunds, disputes, fees, and supplier payouts.

All are Version 1 scope and will be implemented behind backend feature flags after their rules are approved.

## Approval record

The product owner must approve or amend each proposed decision:

| Decision | Recommendation | Status |
| --- | --- | --- |
| FC-01 | Integer minor-unit money, one currency per journal, no core FX conversion | Pending |
| FC-02 | First-class tenant ledger accounts and control/subledger model | Pending |
| FC-03 | Immutable balanced journals, idempotent posting, reversal-only correction | Pending |
| FC-04 | Separate ledger, pending, reserved, and available balances | Pending |
| FC-05 | Provider-neutral idempotent payment and payout state machines | Pending |
| FC-06 | Daily provider/bank reconciliation with zero unexplained variance gate | Pending |
| FC-07 | Effective-dated configurable limits/KYC rules; no hard-coded legal claims | Pending |
| FC-08 | Audited opening-balance migration and derived legacy balance caches | Pending |

Approval status: `pending`

Approved by: _pending_

Approval date: _pending_

Approved exceptions: _none recorded_
