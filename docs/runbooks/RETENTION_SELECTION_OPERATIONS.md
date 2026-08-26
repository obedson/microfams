# Retention selection worker operations

The retention selection worker processes planned dry-run records only. It calls the approved database selection function with a derived request hash and idempotency key; it never deletes source records or bypasses legal holds.

## Verification

```bash
npm --prefix backend test -- --runInBand src/tests/retentionSelectionWorker.test.ts
```

The platform-admin commands create a dry run and select items explicitly. The five-minute worker is recovery-safe: it scans planned rows, continues after an individual failure, and reports scanned/completed/failed counts.

## Operations and recovery

- Review worker logs and planned-run age; repeated failures require investigation, not manual row edits.
- A worker restart is safe because selection is idempotent and source records remain intact.
- If the retention dependency or policy configuration is degraded, disable the retention dry-run feature flag and keep existing records unchanged.
- Resume only after the policy/configuration issue is corrected and a focused worker test plus reconciliation check pass.
- Execute deletion or purge only through the separately approved retention workflow after legal holds, audit evidence, and rollback requirements are satisfied.
