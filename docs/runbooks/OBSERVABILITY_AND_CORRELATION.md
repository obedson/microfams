# Observability and correlation operations

Every HTTP request receives a UUID correlation identifier. A valid `x-correlation-id` is preserved; malformed or missing values are replaced with a generated identifier and returned in the response header. Domain commands that persist audit evidence must pass the correlation identifier through their service/database contract.

## Verification

Run from the Codespace:

```bash
npm --prefix backend test -- --runInBand src/tests/requestContext.test.ts src/tests/outboxOperationsApi.test.ts
```

The health endpoint is a liveness signal only. Queue, database, provider, and reconciliation health must be reviewed through their domain-specific checks; a green liveness response does not certify financial or provider readiness.

## Operations

- Include correlation identifiers in structured error, audit, queue, and recovery logs.
- Do not log secrets, identity numbers, full payment details, or raw webhook payloads.
- Alert on elevated 5xx rates, repeated provider failures, stale outbox leases, database errors, and reconciliation variance.
- Link incident timelines, audit records, and recovery commands by correlation identifier.

## Recovery

If correlation propagation or health evidence regresses, keep existing records intact, disable only the affected new operation where possible, preserve logs and audit rows, and deploy a reviewed forward fix. Re-run correlation tests, affected domain checks, security scans, and reconciliation before re-enabling the operation.
