# Booking foundation operations

Booking creation, reservation holds, state transitions, pricing snapshots, payouts, refunds, and disputes are tenant-scoped workflows backed by database commands and immutable evidence. Operators correlate every command, notification, provider attempt, and recovery action using the request correlation ID and idempotency key.

## Monitoring

Review stale reservation holds, invalid state transitions, payment or payout exceptions, pending refunds, unresolved disputes, and notification dead letters. Confirm the booking, acting organization, provider/customer organizations, pricing snapshot, settlement state, and audit evidence before taking action.

## Rollback and recovery

Disable only new booking acquisition or provider submission with the relevant backend feature flag during an incident. Do not edit bookings, holds, pricing snapshots, settlement journals, payout records, or dispute decisions directly. Use the approved cancellation, refund, dispute-resolution, payout-recovery, or compensating-journal command. Preserve existing records and re-run reconciliation before re-enabling the affected workflow.

## Verification

Run booking lifecycle, reservation, settlement, refund, dispute, payout, notification, tenant-isolation, and E2E checks in CI. Confirm duplicate idempotency requests return the original outcome and cannot create additional holds, journals, payouts, or refunds.
