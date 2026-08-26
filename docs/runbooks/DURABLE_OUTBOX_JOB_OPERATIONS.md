# Durable outbox and job operations

The booking notification outbox is the reference durable-job implementation for WP-P1-005. Domain writes enqueue tenant-scoped events; workers lease pending work, apply bounded retries, and retain terminal/dead-letter evidence independently of financial state.

## Verification

Run from the Codespace:

```bash
npm --prefix backend test -- --runInBand src/tests/bookingNotificationOutboxService.test.ts src/tests/outboxOperationsApi.test.ts
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
