# Durable outbox and job operations

The booking notification outbox is the reference durable-job implementation for WP-P1-005. Domain writes enqueue tenant-scoped events; workers lease pending work, apply bounded retries, and retain terminal/dead-letter evidence independently of financial state.

## Payment timeout execution leases

The payment timeout worker polls every five minutes for one deterministic UTC
hour slot. The database permits only one active worker lease for that slot.
Failed runs retry with bounded exponential backoff, expired leases can be
reclaimed, and successful runs retain aggregate result evidence. Tenant clients
cannot read or operate the execution table or its functions.

Inspect `durable_job_executions` using service-role operational access only.
For `payments.timeout-cancellation`, alert on `retry` or `dead_letter`, leases
past `lease_expires_at`, and hourly slots without `succeeded` evidence.

Do not manually mark a run successful. Restore the failed dependency and allow
the scheduler to reclaim the slot. The underlying timeout command is
idempotent and re-evaluates current booking/payment state on every retry.

## Provider event drain leases

Verified inbound-payment and payout webhook events remain durable in their
provider-event tables. The combined drain polls every minute under
`financial.provider-event-drain`. A database advisory transaction lock and
active-lease check prevent overlapping schedule slots across application
instances.

Item failures remain in `received` state and are retried by the next successful
drain. Queue-selection or storage failures mark the execution `retry` with
bounded backoff; an expired process lease can be reclaimed. Completion evidence
records payment/payout batch sizes, processed items, and failed items without
copying provider payloads into the job record.

## Verification

Run from the Codespace:

```bash
npm --prefix backend test -- --runInBand src/tests/bookingNotificationOutboxService.test.ts src/tests/outboxOperationsApi.test.ts
npm --prefix backend test -- --runInBand src/tests/paymentTimeoutJob.test.ts
npm --prefix backend run test:schema
npm --prefix backend test -- --runInBand src/tests/providerEventDrainService.test.ts
```

The platform-admin outbox health endpoint reports aggregate state counts without exposing event payloads. Queue health must be reviewed alongside worker logs and database counts.

## Operating procedure

- Confirm pending, processing, delivered, failed, and dead-letter counts.
- Confirm leases are advancing and retry age is within the configured threshold.
- Investigate repeated failures using the event identifier and correlation evidence; do not edit outbox rows manually.
- Keep dead-letter records for review and replay only through an approved, idempotent command.
- If a provider or notification dependency is degraded, disable new notification production where supported while preserving queued records.

## Recovery and rollback

A worker restart safely allows expired leases to be reclaimed. For persistent failure, pause the worker or disable the affected feature, preserve the queue, correct the provider/configuration issue, then replay verified records through the worker. Never delete pending or dead-letter rows to make health appear green. Re-run queue health, unit/integration tests, and reconciliation before re-enabling processing.

Rollback the payment-timeout scheduler code only after stopping all workers. Preserve `durable_job_executions`; dropping the table removes incident and retry evidence and is not an operational rollback.

For provider-event drain rollback, stop all workers before restoring the legacy scheduler. Preserve provider-event rows and durable executions, then confirm no active lease remains before restarting one processing path.
