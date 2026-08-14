# Investment oversubscription refund servicing proposal

Status: proposed for product-owner approval

## Purpose

Define the accounting, provider servicing, recovery, and reconciliation rules for refunding the unallocated portion of an approved INV-06 plan. This does not approve valuation, returns, transfers, redemption, secondary trading, or off-rail compensation.

## Domain boundary

Investment subscriptions are bound to provider settlements, not canonical inbound payments. Version 1 must not fabricate payment records to satisfy the payment-specific payment_refunds contract.

INV-07 should create settlement-linked investment refund obligations that pin the tenant, approved plan and item, subscription, settlement, investor, amount, currency, original provider/environment, policy evidence, correlation ID, idempotency key, and request hash. Shared provider adapters and recovery infrastructure may be reused, but investment refund rules remain in the investment domain.

## Eligibility and amount

An obligation may be created only for an approved plan item with a positive refund due, matching tenant evidence, and a posted or reconciled original settlement with an immutable journal. There is exactly one obligation per plan item.

The amount is exactly the approved refund_due_minor. Operators cannot override, split, increase, discount, net, or redirect it. Changed amounts require a corrected allocation plan under a separately approved correction workflow.

## Accounting

Creating an obligation posts no external cash movement. It posts one balanced reclassification journal:

- debit investor_subscriptions_payable; and
- credit a new investment_refunds_payable purpose.

The journal is tenant-scoped, currency-matched, idempotent, linked to the plan item and settlement, and leaves the original settlement journal immutable. The payable is not fee revenue, redemption, dividend, wallet credit, or allocated principal.

Only verified provider success posts external movement:

- debit investment_refunds_payable; and
- credit the certified provider-clearing or operating-cash account.

No cash journal is posted for created, submitted, processing, unknown, failed, cancelled, or manual-review states. Provider failure preserves the payable liability. A verified post-success reversal uses a compensating journal to restore the payable; it never edits the successful journal or silently reissues units.

Provider fees are separate expenses and never reduce the approved investor refund.

## Provider routing and states

Refunds return through the original settlement provider and original rail where supported. Unsupported routing enters manual_review; Version 1 does not automatically redirect funds to a wallet, bank account, or different provider.

Recommended states are created, submitted, processing, unknown, succeeded, failed, manual_review, and reversed. Timeouts and ambiguous responses never produce synthetic success. Failed attempts remain recoverable under the same durable obligation.

Live submission requires credentials, signed webhook verification, replay protection, provider certification, reconciliation readiness, and the applicable live-provider flag.

## Orchestration, recovery, and reconciliation

One idempotent command creates all positive obligations for an approved plan and posts their reclassification journals atomically. Provider submission runs through a recoverable worker. Every attempt records an attempt number, request hash, state, timestamps, and masked provider reference.

Duplicate workers, callbacks, and retries cannot duplicate obligations, provider submissions, journals, or unit execution. Reconciliation covers exact success, duplicates, timeout followed by late success, missing local/provider evidence, unsupported partial refunds, failures, reversals, fee differences, and zero unexplained variance.

Exceptions preserve the refund liability and block false completion. Disabling new subscriptions does not block servicing existing obligations. Emergency provider disablement pauses submission but not recovery queries, verified callbacks, reconciliation, statements, or audit access.

## Audit and rollback

Audit evidence covers obligation creation, liability posting, provider attempts/results, retry, reconciliation, exception, success, and reversal. Logs contain masked references and no secrets, raw tokens, or full bank details.

Before durable obligations, rollback may remove empty tables after disabling servicing. After any obligation or journal exists, preserve evidence and use forward correction.

## Approval decisions

| Decision | Recommendation | Status |
| --- | --- | --- |
| INV-07A | Use settlement-linked investment refund obligations instead of fabricated payment records | Proposed |
| INV-07B | Debit investor_subscriptions_payable and credit new investment_refunds_payable when recognizing obligations | Proposed |
| INV-07C | Post cash movement only after verified provider success; failure preserves the payable | Proposed |
| INV-07D | Require original-provider/original-rail routing; unsupported routing enters manual review | Proposed |
| INV-07E | Keep provider fees separate and never reduce the approved investor refund | Proposed |
| INV-07F | Permit unit issuance after every obligation and reclassification journal exists, without waiting for provider success | Proposed |
| INV-07G | Restore refund payable through a compensating journal after verified post-success reversal | Proposed |

## Required acceptance evidence

CI must prove exact obligation amounts, one obligation per plan item, balanced/idempotent reclassification, immutable settlement journals, provider success/failure/timeout/unknown/duplicate/late-success/reversal contracts, no premature cash journal, retry and webhook replay safety, tenant isolation, feature enforcement, reconciliation with durable exceptions and zero unexplained variance, unit-issuance gating according to INV-07F, clean and legacy migrations, rollback, recovery, audit, and security.

Approved by: _pending_

Approval date: _pending_

