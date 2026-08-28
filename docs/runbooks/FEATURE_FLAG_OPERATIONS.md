# Feature-Flag Operations and Rollback

This runbook defines the operational evidence required for server-owned feature flags. Flags are evaluated only by backend services; client presentation never authorizes a command.

## Safe change procedure

1. Confirm the flag key is registered in `backend/src/config/featureFlagCatalog.ts` and that its default and failure mode match the approved specification.
2. Open a change or incident record with the tenant, environment, effective window, intended state, reason, risk classification, and rollback condition.
3. For regulated or provider flags, obtain independent approval. The approver must be a different actor from the author.
4. Apply the override through the trusted backend administration path. Direct client access to `feature_flags` and `feature_flag_overrides` is prohibited by RLS and revoked grants.
5. Verify the effective decision for the target tenant and environment, then exercise one denied or enabled command in a non-production environment.
6. Confirm audit evidence contains the key, actor, reason, before/after values, and timestamp. Never place secrets or identity numbers in the reason.

## Administration API

All routes require an authenticated active platform-administrator assignment:

- `GET /api/admin/feature-flags` lists the registered catalog.
- `GET /api/admin/feature-flags/:key/effective` evaluates an explicit environment and optional tenant, jurisdiction, or actor context.
- `POST /api/admin/feature-flags/:key/overrides` proposes an effective-dated override with a mandatory reason.
- `POST /api/admin/feature-flags/overrides/:overrideId/decision` independently approves or rejects a pending provider or regulated override.
- `POST /api/admin/feature-flags/:key/emergency-stop` changes the emergency stop with a mandatory incident reference.
- `GET /api/admin/feature-flags/audit` returns immutable before/after evidence.

Standard-risk overrides are approved by the proposing platform administrator. Provider and regulated overrides remain pending and cannot affect runtime evaluation until a different platform administrator approves them. Rejected and revoked rows never participate in evaluation.

## Emergency stop

Emergency stop is reserved for an active security, legal, provider, or ledger-integrity incident. Record the incident reference, authorized operator, reason, affected scope, and expected review time. The stop must fail closed for new exposure while preserving reads and servicing paths whose catalog failure mode is `open`.

After activation, verify:

- new acquisition commands return the standard feature-disabled error;
- callbacks, reconciliation, refunds, reversals, withdrawals, and statements remain processable where their servicing flag is enabled;
- the change appears in `feature_flag_audit_log`;
- alerts are raised for repeated evaluation/storage failures and unexpected emergency-stop changes.

## Rollback and recovery

Rollback is an additive configuration change: restore the prior effective override or disable the affected acquisition flag. Do not delete audit rows, mutate posted financial records, or hide existing obligations. If a provider operation is in flight, leave it in pending/reconciliation state and process the callback idempotently.

Before re-enabling a regulated or live-provider flag, confirm credentials, provider health, reconciliation certification, compliance approval, and tenant-specific activation evidence. If any item is missing, remain fail closed.

## Verification evidence

Attach the deployment/change record, effective-decision check, audit-log query, alert outcome, and rollback or recovery result to the release or incident record. These artifacts are required for V1 operational acceptance.
