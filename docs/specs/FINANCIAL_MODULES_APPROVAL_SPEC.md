# Micro Fams V1 Financial Modules — Approval Specification

Status: **PROPOSED — requires product-owner approval before implementation**  
Scope: wallets, payments, escrow, savings, investments, loans/credit, dividends/profit sharing, and cooperative accounting.

## 1. Product and regulatory boundary

Micro Fams will implement complete, real-money-capable workflows behind server-side feature flags. A disabled product must reject new transactions at the API and worker layers while preserving authorized read access, reconciliation, settlement, and withdrawal of existing obligations. UI hiding is not a control.

Micro Fams is the system of record for product state and its double-entry subledger. Licensed providers remain the system of record for safeguarded money, bank accounts, payment rails, identity checks, and regulated investment or lending services where required. Launch in a jurisdiction requires recorded compliance approval and an enabled provider configuration.

The platform must never represent a provider test response as settled real money. Sandbox and live modes use separate credentials, webhooks, accounts, ledgers, and visible environment labels.

## 2. Cross-cutting invariants

1. Every money movement is denominated by ISO currency and stored in integer minor units; no floating-point arithmetic is allowed.
2. Every posted transaction has balanced debit and credit entries. Posted entries are immutable; corrections use linked reversals and replacement entries.
3. Available balance equals posted balance minus active holds. Pending provider events do not increase spendable balance.
4. Every command and provider webhook is idempotent under a tenant-scoped idempotency key or provider event identifier.
5. Tenant ID, legal entity, actor, source account, destination account, product, currency, and correlation ID are recorded on every journal.
6. No tenant may read, operate on, report, or reconcile another tenant's financial data. Platform operators require audited break-glass authorization.
7. A user cannot approve their own controlled disbursement where maker-checker rules apply.
8. Provider callbacks are signature-verified against the raw body, timestamp checked, persisted before processing, and safe to replay.
9. All state transitions are explicit, authorized, audited, and concurrency-safe. Database constraints—not pre-checks alone—protect uniqueness and non-negative limits.
10. Daily provider-to-ledger and bank-to-ledger reconciliation produces matched, unmatched, duplicate, late, and amount-mismatch queues.

## 3. Accounts and wallet types

The ledger supports separate accounts for user cash, organization cash, group cash, savings principal, investment subscriptions, loan principal receivable, interest/fees receivable, escrow liability, provider clearing, settlement bank, revenue, expenses, dividends payable, suspense, and write-offs.

Customer-visible wallets are views over ledger accounts, not mutable balance columns. V1 wallet types are personal, group/cooperative, organization/programme, savings, investment, loan-disbursement, escrow, and rewards/promotional. Promotional value is never withdrawable or mixed with safeguarded cash.

Transfers require active accounts, matching currencies, sufficient available balance, transaction limits, risk checks, and authorization. Cross-currency transfers are out of scope until an approved FX provider and explicit quote workflow exist.

## 4. Payments and payout services

Supported workflows are collection initialization, provider authorization, asynchronous confirmation, allocation, receipt, refund, reversal, payout initiation, payout approval, provider submission, completion/failure, retry, and reconciliation.

- A client redirect is never proof of payment; only a verified provider event or server-to-server verification can settle a collection.
- Fees and taxes are itemized before authorization and posted to distinct accounts.
- Refunds cannot exceed the captured, unrefunded amount and return funds to the original rail unless compliance approves an exception.
- Payout beneficiary changes require step-up authentication and a cooling period configurable by tenant and risk tier.
- Transaction, daily, and rolling limits are configurable by product, tenant, role, KYC tier, currency, and risk tier.

## 5. Escrow

An escrow contract records payer, beneficiary, amount, purpose, milestones, inspection evidence, release rules, dispute window, expiry, and authorized arbiters. Funding moves customer cash into an escrow liability account; it is not platform revenue.

States: `draft -> awaiting_funding -> funded -> active -> release_pending -> released`, with terminal alternatives `cancelled`, `refunded`, and `resolved`. A dispute moves an eligible contract to `disputed` and freezes automated release.

Release may be single or milestone-based. Each milestone requires configured evidence and the required approvals. Partial releases reduce only the relevant held amount. Expiry never silently transfers funds: it follows the contract's approved refund/release rule and creates notifications and an audit event.

## 6. Savings

Savings products define eligibility, currency, minimum/maximum contribution, frequency, target, lock period, grace period, early-withdrawal rule, return/interest rule, fees, and disclosure version.

Enrollment requires acceptance of the exact disclosure version. Contributions may be manual or mandate-based. Failed recurring contributions do not create debt unless the product explicitly defines a disclosed commitment. Withdrawals respect holds, lock rules, provider liquidity, KYC, and approval limits.

Returns are calculated with a versioned formula and day-count convention, accrued separately, and posted only after approval. No guaranteed return may be displayed unless legally supported by the configured product/provider.

## 7. Investments

An investment product defines issuer/operator, underlying farm/project, risk disclosure, funding target, minimum/maximum subscription, offer window, unit or ownership method, fees, expected—not guaranteed—return, loss allocation, reporting schedule, maturity, exit rules, and jurisdictional eligibility.

Lifecycle: `draft -> compliance_review -> approved -> open -> funded -> active -> maturing -> settled`, with `cancelled`, `failed`, or `written_down` alternatives. Subscriptions remain pending until money settles and allocation succeeds. Oversubscription follows a declared first-settled or pro-rata policy; the default proposal is pro-rata with automatic refund of excess.

Valuations and performance reports are versioned, source-attributed, and never rewrite prior statements. Losses, delays, restructures, and conflicts of interest must be disclosed. Secondary trading is excluded unless separately approved and licensed.

## 8. Loans and credit

Loan products define lender/provider, eligible borrower types, purpose, principal limits, tenor, repayment frequency, interest method, APR/effective cost disclosure, fees, grace period, collateral/guarantee rules, affordability rules, delinquency stages, restructuring, and write-off policy.

Lifecycle: `draft -> submitted -> identity_review -> affordability_review -> credit_review -> offered -> accepted -> disbursement_pending -> active -> paid_off`, with `declined`, `withdrawn`, `cancelled`, `delinquent`, `defaulted`, `restructured`, and `written_off` paths.

- Credit decisions store input facts, rule/model version, result, reason codes, reviewer, and overrides.
- Acceptance binds the borrower to the exact offer and disclosure version; material changes require a new offer.
- Disbursement occurs only after all conditions precedent pass and provider confirmation is received.
- Repayments allocate in a configurable, disclosed order. Proposed default: statutory charges, collection costs, penalties, accrued interest, then principal; jurisdictional rules override this.
- Penalties never compound unless explicitly lawful and approved. Total cost, outstanding principal, accrued interest, fees, arrears, and payoff quote are separately visible.
- Automated adverse decisions provide understandable reason codes and a human review/appeal route.

## 9. Dividends and profit sharing

A distribution declares the source period/project, distributable amount, retained reserves, eligibility record date, allocation formula, tax/withholding rule, approval quorum, and payment date. The entitlement snapshot is immutable after approval.

Proposed default allocation is proportional to eligible paid units or shares at the record date. Patronage-based, contribution-based, or hybrid formulas are supported only as versioned tenant rules. Rounding residuals post to a disclosed residual account and never to an operator's personal wallet.

Lifecycle: `draft -> calculated -> reviewed -> approved -> payable -> paying -> paid`, with reversal through a separate corrective distribution. No distribution may be approved when it would violate reserves, solvency constraints, restricted-fund rules, or project covenants.

## 10. Cooperative and organization accounting

V1 provides a tenant-scoped chart of accounts, fiscal periods, journals, receivables, payables, member capital, contributions, expenses, budgets, bank/provider reconciliation, trial balance, income statement, balance sheet, cash-flow report, member statements, project/farm cost centers, and immutable audit exports.

Fiscal periods can be closed only after reconciliation and approval. Reopening requires privileged approval and creates an audit event. Restricted grant/programme funds use separate accounts and cost centers; reports must show budget versus actual and prohibited-category exceptions.

The operational subledger and general ledger integrate through versioned posting rules. A posting failure leaves the originating transaction pending/suspense and alertable; it must never create an unbalanced journal.

## 11. Approvals, controls, and configurable rules

Rules are versioned, effective-dated, tenant-scoped, and validated against platform safety bounds. Configuration changes require authorization and audit history; high-risk changes require maker-checker approval.

Configurable dimensions include product availability, KYC tier, transaction limits, fees, interest/return formulas, repayment allocation, approval thresholds/quorums, eligible roles, lock/grace periods, dispute windows, reserve ratios, provider routing, retry policy, and notification schedule.

Feature flags are server-owned and evaluated with tenant, jurisdiction, environment, product, and actor context. At minimum each financial domain has `read`, `enrol/create`, `fund/transact`, and `admin/configure` controls plus a global emergency stop. Disabling transaction creation must not disable webhooks, reconciliation, reversals, refunds, statements, or legally required servicing.

## 12. Required evidence and test acceptance

Before live enablement each product requires approved legal/compliance notes, provider contract and live credentials, sandbox certification, threat model, data-protection review, support/runbook, reconciliation sign-off, limits, disclosures, and named operational owners.

Automated acceptance must cover unit calculations, state machines, authorization, tenant isolation, database posting/locking, API contracts, webhook replay/signatures, provider adapters, frontend disclosures and approvals, end-to-end happy/failure/dispute/reversal flows, property-based ledger invariants, concurrency, recovery, reconciliation, and live-provider smoke tests in a controlled test tenant.

## 13. Decisions requested from the product owner

Please approve or amend these proposed defaults before financial implementation:

1. Use regulated providers as custodians/rails while Micro Fams maintains the operational double-entry subledger.
2. Use pro-rata allocation for oversubscribed investments.
3. Allocate loan repayment to statutory charges, collection costs, penalties, interest, then principal, subject to jurisdictional law.
4. Use proportional paid units/shares as the default dividend formula, with tenant-specific versioned alternatives.
5. Require maker-checker approval for payouts, product/rule changes, distributions, write-offs, restructures, fiscal-period reopening, and manual ledger corrections.
6. When a feature is disabled, block new exposure but continue servicing, webhooks, reconciliation, refunds/reversals, statements, and withdrawals required to protect customers.
7. Exclude cross-currency transfers and secondary investment trading until separately specified and approved.

