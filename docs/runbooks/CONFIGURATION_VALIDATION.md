# Backend configuration validation and secret inventory

This runbook records the WP-P0-005 controls for backend startup configuration and secret ownership. It lists secret names and purposes only. Never add secret values to this file, source control, logs, issues, pull requests, or reconciliation artifacts.

## Startup contract

The backend loads environment variables once through `backend/src/config/environment.ts` and validates the result before constructing database clients or accepting traffic.

Required in every environment:

- `SUPABASE_URL` must be an HTTP or HTTPS URL.
- `SUPABASE_SERVICE_KEY` must be present.
- `JWT_SECRET` must be a non-default value containing at least 32 characters.
- `NODE_ENV`, when supplied, must be `development`, `test`, `staging`, or `production`.
- `PORT`, when supplied, must be an integer from 1 through 65535.

Production additionally requires:

- `JWT_REFRESH_SECRET` containing at least 32 characters.
- `FRONTEND_URL` containing an HTTP or HTTPS URL.

Invalid configuration raises `ConfigurationValidationError` during module startup. Error messages identify variable names and validation rules but never include supplied values.

## Secret inventory

`SECRET_INVENTORY` is the typed, value-free application inventory. Each entry records the environment-variable name, whether it is always, production, or provider dependent, and its purpose.

When code begins consuming a new secret:

1. Add its name and purpose to `SECRET_INVENTORY`.
2. Add the deployment-owner instructions to `docs/CREDENTIALS_SETUP.md`.
3. Add validation to the relevant provider activation contract before live routing.
4. Add tests proving missing or invalid configuration fails closed without leaking the value.

Provider-dependent secrets remain disabled behind backend feature flags until credentials, provider environment, approvals, webhook verification, and reconciliation evidence are present. A configured value alone does not authorize live operation.

## Deployment verification

Before deployment:

```bash
npm --prefix backend test -- --runInBand src/tests/environmentConfig.test.ts
npm --prefix backend run typecheck
```

Populate secrets through the environment-scoped deployment secret manager. Use separate values for test, staging, and production. Start the release candidate and confirm:

- startup succeeds without configuration warnings;
- `GET /health` succeeds;
- logs contain environment names and variable names only, never secret values;
- disabled provider workflows continue to reject new live operations;
- database and token-signing smoke tests use the intended environment.

## Failure handling

If startup reports invalid configuration, do not weaken validation or add a source-code fallback. Keep the deployment unavailable, identify the named variable, correct it in the secret manager, and redeploy the same reviewed commit.

If a secret may have been exposed, disable the affected provider or workflow, rotate the value, preserve audit evidence, redeploy, and reconcile any external operations before re-enabling it. Follow the provider-specific runbook for webhook replay and settlement checks.

## Rollback and recovery

Application rollback does not restore or rotate secrets. Roll back to the last reviewed release only when its configuration contract is compatible with the current secret set. Never reintroduce placeholder JWT keys or bypass startup validation to recover service.

For an incompatible configuration change:

1. Disable affected provider flags and stop new external mutations.
2. Restore the previous release's required variable names in the secret manager.
3. Deploy the previous reviewed commit.
4. Run health, authentication, tenancy, and provider-disabled smoke checks.
5. Reconcile queued or pending financial operations before normal traffic resumes.

After recovery, correct the forward release and rerun CI. Do not edit a production database manually.
