# Savings Product Operations

## Scope

This runbook covers SAV-01 product versioning, disclosure-bound enrolment, and canonical savings-account provisioning. It applies per organisation and does not authorize direct database mutation.

## Product lifecycle

1. A configured operator creates a draft product with integer minor-unit limits, eligibility rules, a disclosure version, and its SHA-256 content hash.
2. A different configured operator submits the draft and approves it. The database rejects self-approval and requires an immutable active version.
3. The client enrolment flow reads only active products, displays the exact disclosure version/hash, and sends both values with an idempotency key.
4. The service verifies organisation membership, product state, disclosure equality, and idempotency before creating the enrolment and its canonical principal and accrued-return ledger accounts.

## Evidence checklist

- Confirm the organisation and actor are present and active.
- Capture product code, product version, disclosure version, and disclosure hash.
- Confirm maker and checker are different users and both commands have audit events.
- Confirm the enrolment idempotency key is unique for the organisation.
- Confirm both canonical financial accounts were provisioned in the same transaction and use the product currency.
- Confirm no raw disclosure content, identity numbers, or provider credentials are written to logs.

## Failure and recovery

Rejected lifecycle transitions, stale versions, disclosure mismatches, duplicate idempotency keys, and failed account provisioning must remain visible as failed command/audit evidence. Retry with the same idempotency key only when the original outcome is unknown; do not create a second enrolment key. If provisioning is incomplete, quarantine the command, reconcile the enrolment and account records, and use a compensating migration or service command approved by finance operations. Never update posted journal rows or balances manually.

## Rollback

Disable the tenant/environment savings enrolment flag to stop new enrolments while preserving existing accounts and history. Retire the active product through its governed lifecycle. Existing financial accounts and journal evidence remain queryable for reconciliation and support.
