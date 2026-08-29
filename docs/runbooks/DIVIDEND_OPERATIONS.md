# Dividend and profit-sharing operations

Dividend entitlement, approval, payable recognition, and payment are separate commands. Each command is tenant scoped, permission checked, idempotent, correlated, and backed by immutable database evidence.

## Operations

Monitor rejected or pending distributions, payable-recognition failures, provider/payment exceptions, and reconciliation variance. Confirm the effective date, eligibility snapshot, withholding metadata, journal IDs, correlation ID, and idempotency key for every operational investigation. Never edit distribution, entitlement, payable, or journal rows directly.

## Rollback and recovery

Disable only the dividend acquisition or payment feature flag when an incident is active; continue read access and servicing of already-posted records. A posted journal is immutable. Correct an erroneous entitlement, payable, or payment through the approved compensating-journal or reversal workflow, preserving the original correlation and audit evidence. Re-run tenant reconciliation and verify zero unexplained variance before re-enabling payment.

## Verification

Run the dividend service/API tests and the clean-schema financial migration checks in CI. Confirm that duplicate idempotency keys return the original result and that a second payment cannot create another payable or journal.
