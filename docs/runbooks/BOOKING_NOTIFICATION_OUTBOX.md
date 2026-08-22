# Booking notification outbox

## Guarantees

Booking money transitions enqueue tenant-aware notification events in the same database transaction. Delivery happens later, so a notification-provider failure never rolls back payment custody, completion, disputes, refunds, payouts, reversals, or recovery accounting.

Platform administrators can inspect aggregate queue health at `GET /api/admin/operations/outbox/booking-notifications`. The response contains only counts by state and a total; it does not expose event payloads, event keys, recipient identifiers, or dispute evidence.

Covered events are payment custody, service completion, dispute deadline, dispute opening, evidence request, resolution proposal/approval, refund state, payout state, reversal, and recovery.

## Worker controls

The production booking job runs once per minute. Each run:

1. claims a bounded batch using `FOR UPDATE SKIP LOCKED`;
2. records a 60-second lease and increments the durable attempt count;
3. writes idempotent in-app notifications for active members of the recipient organization;
4. marks successful events delivered; or
5. schedules exponential retry from the supplied deterministic clock.

Retry delay starts at 30 seconds and is capped at one hour. Events stop after eight attempts and retain `dead_letter` state, a stable failure code, attempt count, timestamps, tenant, booking, and public event payload.

## Incident response

If the queue grows or dead letters appear:

1. keep all financial servicing workflows enabled;
2. inspect counts by recipient organization and event type without exposing payloads;
3. restore the database or notification dependency;
4. allow expired leases and scheduled retries to resume normally;
5. investigate dead letters, correct the root cause, and use a separately approved replay command when that workflow is added.

Never edit financial records to force a notification. Never copy private dispute evidence or unmasked payout destinations into the outbox.
