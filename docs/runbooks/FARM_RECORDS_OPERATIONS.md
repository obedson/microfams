# Farm Records Operations and Recovery

## Scope

The farm-record workflow stores livestock activity, counts, feed consumption, mortality, expenses, notes, dates, and optional property or booking linkage. All record queries and mutations are scoped by the resolved organization and authenticated farmer.

This increment validates the existing web journey. It does not claim that the wider Phase 6 calendar, labour, inputs, yield, evidence-upload, or offline-sync requirements are complete.

## Deployment verification

1. Enable the farm operations capability only for an approved tenant.
2. Sign in as a farmer with an active organization.
3. Open `/farm-records`, create a livestock record, and verify it appears in Recent Records and the analytics totals.
4. Confirm requests include the active organization header and that another tenant or farmer cannot update, delete, or link the record.
5. Run `npm run test:e2e` in `frontend`; the farm-record smoke uses deterministic intercepted API responses and no production data.

## Monitoring

Monitor farm-record API 4xx/5xx rates by tenant and correlation identifier. Alert on repeated cross-tenant no-row responses, invalid booking/property linkage, or sustained create failures. Do not log record notes if they may contain personal or sensitive farm information.

## Disable and recovery

Disable new farm-operation mutations at the backend before rolling back an unsafe release. Existing records must remain readable and exportable; do not delete or rewrite them. Restore service with a forward fix, rerun the tenant-isolation/API tests and browser smoke, then re-enable mutations for the affected tenant.

Database corrections use a forward migration. Never repair farm records manually in production. A rollback record must include commit, tenant, time, reason, affected record identifiers, and verification result.
