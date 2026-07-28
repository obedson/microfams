# Booking Cancellation and Refund Rules

Status: proposed for product-owner approval.

## Purpose

This specification defines the Version 1 product rules for cancelling a property booking and refunding a captured booking payment. It specializes the approved FC-01 through FC-08 financial core without changing those invariants.

After approval, this specification supersedes conflicting or incomplete cancellation and refund behaviour in `.kiro/specs/farmle-platform-enhancement/`, the legacy `refunds` table workflow, and direct provider calls in application services.

## Scope

This specification covers:

- cancellation by the booking farmer or property owner;
- cancellation before and after the booking start date;
- full and partial refunds of captured booking payments;
- automatic and manually approved refunds;
- provider submission, recovery, reconciliation, accounting, audit, notifications, and user-visible status; and
- deterministic, sandbox, and feature-flagged live-provider operation.

Disputes, chargebacks, property-damage claims, cancellation penalties, marketplace refunds, and off-rail compensation require their own approved product rules. They must not be simulated through a booking refund.

## Proposed decisions

### BR-01 — Authorized cancellation actors

1. A booking may be cancelled only by its farmer, the owner of the booked property acting through the provider organization, or an explicitly assigned booking-support role.
2. Organization membership alone does not authorize cancellation. Authorization must be bound to the booking and the actor's organization-scoped permission.
3. A platform administrator has no implicit right to cancel a tenant booking or move its money.
4. Every accepted and denied cancellation command records the actor, acting organization, booking customer organization, provider organization, reason, correlation ID, and time.

### BR-02 — Cancellable booking states

1. `pending_payment`, `pending`, and `confirmed` bookings may be cancelled.
2. `cancelled` commands are idempotent only when the original idempotency key and request facts match.
3. `completed` bookings cannot be cancelled. Any financial claim after completion must enter the future dispute workflow.
4. A non-empty reason between 2 and 500 characters is required.

### BR-03 — Cancellation timing

1. A cancellation before the booking start date is an automatic-policy cancellation.
2. A cancellation on or after the booking start date but before completion is accepted operationally, but any refund requires manual review because Version 1 has no approved consumed-time or damage-allocation formula.
3. Date comparison uses the booking's recorded tenant timezone; the platform default is `Africa/Lagos` until a tenant configures another supported timezone.
4. Changing a booking date after a cancellation request cannot change the policy snapshot used by that request.

### BR-04 — Default refund entitlement

1. An unpaid booking creates no refund obligation.
2. A captured, unrefunded payment for a cancellation before the start date is eligible for a full refund of the remaining refundable principal.
3. No cancellation penalty or platform cancellation fee is deducted in Version 1 unless a later approved, versioned rule and customer disclosure explicitly introduces one.
4. A cancellation on or after the start date creates `manual_review`; it does not automatically submit a full or pro-rata refund.
5. A completed booking has no automatic refund entitlement under this workflow.

### BR-05 — Refund amount and fee treatment

1. Money is stored and calculated in integer minor units in the payment currency.
2. The maximum refundable amount is captured principal minus all succeeded and non-terminal in-flight refunds.
3. Full and partial refunds are supported, but cumulative refunds can never exceed the captured amount.
4. Provider fees are accounted for separately from principal. A provider fee that is not refunded remains a platform/provider expense and is not silently deducted from the customer's approved refund.
5. Taxes, penalties, damages, credits, goodwill payments, or off-rail payments cannot be embedded in the refund amount without a separately approved rule.

### BR-06 — Approval rules

1. A pre-start full refund mechanically derived from this approved policy may be created automatically when the cancellation is accepted.
2. A partial refund, post-start refund, amount override, off-rail exception, or operator-created refund requires an explicit refund permission and maker-checker approval.
3. The requester cannot approve the same manual refund.
4. An approval binds the payment, booking, amount, currency, reason code, policy version, maker, checker, and expiry. Any changed fact requires a new approval.

### BR-07 — Atomic cancellation workflow

1. One idempotent database command locks the booking and its canonical payment, verifies tenant and actor authorization, snapshots the policy, cancels the booking, and creates either no refund obligation, an automatic refund, or a manual-review request.
2. Cancellation does not wait for an external provider call. Once accepted, the booking remains cancelled even while its refund is pending, failed, or under review.
3. A database or invariant failure rolls back the entire cancellation command.
4. Notification failure never rolls back a durable cancellation or financial obligation.

### BR-08 — Provider-neutral refund servicing

1. Controllers, booking services, and models must not call Paystack or another provider directly.
2. Refund submission uses the provider adapter recorded on the original canonical payment and returns funds to the original rail.
3. A synchronous timeout leaves the refund in a recoverable `processing` state; it is never reported as succeeded.
4. Provider state is confirmed by a verified webhook or server-to-server query before a refund journal is posted.
5. A failed provider submission preserves the refund obligation and makes it retryable or reviewable with the same financial identity.
6. Live routing requires the approved live-provider flag, credentials, account configuration, webhook verification, and reconciliation certification. Missing live configuration never produces a fake success.

### BR-09 — States and user-visible behaviour

1. Cancellation requests expose `accepted`, `refund_not_required`, `refund_created`, `refund_processing`, `refund_succeeded`, `refund_failed`, and `manual_review` outcomes.
2. Canonical refund states remain `created`, `submitted`, `processing`, `succeeded`, `failed`, and `cancelled`.
3. The booking API and UI display the refund identifier, approved amount, currency, state, reason, and last update without exposing provider tokens or internal evidence.
4. The UI must distinguish deterministic/sandbox money from live money.
5. Farmer and property owner receive durable cancellation and refund-status notifications; messages are retried independently of the financial transaction.

### BR-10 — Accounting and reconciliation

1. Creating or submitting a refund does not post cash movement.
2. Confirmed refund success posts the approved FC-05 compensating journal: debit customer/product funds liability and credit provider clearing.
3. A partial success changes the payment to `partially_refunded`; cumulative full success changes it to `refunded`.
4. Provider fees remain separate entries and are reversed only when provider recovery is confirmed.
5. Refunds participate in provider-event ingestion, settlement reconciliation, duplicate detection, exception investigation, and zero-unexplained-variance reporting.

### BR-11 — Feature flags and incident behaviour

1. Booking cancellation remains available for authorized parties even when new payment acquisition is disabled.
2. Refund creation and servicing use `financial.payments.service_existing`, which follows the approved fail-open servicing policy for existing customer obligations.
3. Emergency disablement may pause an unsafe provider submission but cannot delete, hide, or falsely complete a refund obligation.
4. Webhooks, status recovery, reconciliation, statements, and manual investigation continue while new exposure is disabled.

### BR-12 — Audit, retention, and recovery

1. Cancellation, approval, provider submission, provider result, retry, reconciliation, notification, and manual-review events are auditable and tenant-scoped.
2. Audit data stores reason codes and masked provider references, never secrets, raw tokens, or full identity/bank data.
3. Cancellation and refund records are retained according to the financial-record policy and are never hard-deleted by application workflows.
4. Recovery jobs are concurrency-safe, bounded, observable, and idempotent.

## Required implementation changes after approval

1. Replace direct `refundService.ts` provider calls and delete the placeholder `Payment.ts` refund workflow.
2. Add the atomic booking-cancellation/refund command and canonical cancellation policy snapshot.
3. Link booking cancellation to `payments` and `payment_refunds`, not the legacy `refunds` table.
4. Route automatic and approved manual refunds through `PaymentService` and its recorded provider adapter.
5. Add provider recovery, notification recovery, audit evidence, feature flags, API contracts, and frontend refund states.
6. Migrate or quarantine legacy refund records without fabricating provider success.

## Acceptance criteria

Implementation is complete only when CI proves:

- unit tests for eligibility, timing, amount, cumulative limits, approval, and state mapping;
- database tests for atomic cancellation, replay, tenant isolation, concurrent refunds, immutable journals, and rollback;
- API tests for authentication, party authorization, scoped permissions, validation, flags, and idempotency;
- deterministic adapter tests for success, processing, timeout, failure, replay, and late success;
- frontend component tests for confirmation, pending, manual-review, failed, succeeded, and disabled-provider states;
- end-to-end tests for unpaid cancellation, pre-start paid cancellation, post-start manual review, duplicate requests, provider timeout/recovery, partial refund, and cross-tenant denial;
- reconciliation tests covering partial/full refunds and zero unexplained variance; and
- clean and representative legacy migration tests.

## Approval record

| Decision | Recommendation | Status |
| --- | --- | --- |
| BR-01 | Resource-bound farmer/property-owner cancellation authorization | Proposed |
| BR-02 | Only pending-payment, pending, and confirmed bookings cancellable | Proposed |
| BR-03 | Pre-start automatic policy; post-start manual review | Proposed |
| BR-04 | Full remaining principal before start; no unapproved penalty | Proposed |
| BR-05 | Integer minor units, cumulative cap, provider fees separate | Proposed |
| BR-06 | Automatic policy refund; maker-checker for exceptions/partial/post-start | Proposed |
| BR-07 | Atomic cancellation plus durable refund obligation | Proposed |
| BR-08 | Original-rail, provider-neutral, recoverable asynchronous servicing | Proposed |
| BR-09 | Explicit cancellation/refund UI states and notifications | Proposed |
| BR-10 | Journal only on confirmed success; full reconciliation | Proposed |
| BR-11 | Existing-obligation servicing remains available under flags | Proposed |
| BR-12 | Tenant-scoped immutable audit and idempotent recovery | Proposed |
