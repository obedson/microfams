# Reconciliation Exception Investigation and Resolution

This runbook covers the authorized lifecycle for payment and payout reconciliation exceptions. It applies to tenant-scoped exceptions produced by a persisted reconciliation run.

## Investigate

1. Confirm the exception belongs to the active organization and is still `open`.
2. Review the immutable reconciliation run, provider source evidence, internal payment or payout reference, amount, currency, direction, timestamps, and duplicate or mismatch classification.
3. Start investigation with a reason between 10 and 500 characters using the trusted backend command. The database records the actor, reason, timestamp, and audit event. Replaying the same investigation facts is idempotent; changing them is rejected.
4. Do not edit reconciliation items, provider evidence, journals, payments, payouts, or balances directly.

## Resolve

A resolution request is available only after investigation. Select one of `matched_evidence`, `provider_correction`, `compensating_adjustment`, or `writeoff`, and provide a durable evidence reference and reason. `compensating_adjustment` and `writeoff` require a posted journal whose source domain is `reconciliation.adjustment` or `reconciliation.writeoff`.

The requester and approver must be different authorized tenant actors. The approval command validates the pending approval record, organization, exception state, resolution type, journal ownership, and idempotency key. An approved resolution moves the exception and reconciliation item to `resolved`; a rejection preserves the investigating state for further review.

## Safety and rollback

Never reopen a resolved exception or alter an original posted journal. Corrections use a new compensating journal and a new audited resolution request. If the evidence or provider result is incomplete, leave the exception investigating and continue reconciliation separately. A service rollback disables new manual resolution commands while retaining read access to the exception and audit history.

## Evidence and monitoring

Attach the reconciliation run ID, exception ID, source evidence reference, investigation reason, resolution request ID, approval decision, and compensating journal ID where applicable. Alert on repeated investigation failures, idempotency conflicts, cross-tenant denials, invalid journal references, rejected approvals, and exceptions that remain investigating beyond the support target.