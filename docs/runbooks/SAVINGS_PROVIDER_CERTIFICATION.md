# SAV-06 Savings Provider Certification and Activation

## Purpose

SAV-06 prevents a tenant from opening new savings exposure merely because a feature flag is enabled. Sandbox or live acquisition also requires evidence tied to the exact provider configuration, complete certification scenarios, independent approval, and—when live—an independently approved financial live-activation record.

The database stores evidence references and a SHA-256 configuration fingerprint. It never stores provider credentials, webhook secrets, access tokens, settlement bank details, or raw evidence files.

## Rollout sequence

1. Implement and register a provider adapter using `SAVINGS_PROVIDER_ADAPTER_CODE`.
2. Configure `SAVINGS_PROVIDER_MODE` as `sandbox` and set the provider code, jurisdiction, currency, and configuration fingerprint.
3. Create a tenant certification through `POST /api/savings/provider-certifications` using references to the provider contract, credential validation, webhook test, settlement account validation, compliance notes, threat model, privacy review, runbook, reconciliation sign-off, and limits/disclosures.
4. Record every required scenario through `POST /api/savings/provider-certifications/:id/scenarios`. Failed attempts remain immutable; a later numbered attempt may supersede them for readiness.
5. Submit the evidence set and have a different authorized actor decide it.
6. Verify `GET /api/savings/provider-readiness` reports `ready=true` for the exact configuration fingerprint.
7. For live mode, repeat controlled certification with live configuration and independently approve the matching `financial_live_activations` record for the tenant, jurisdiction, and licensed provider.
8. Enable the tenant acquisition flags only after readiness succeeds. Servicing, statements, reconciliation, rejection, cancellation, and lawful withdrawals remain on their servicing-safe flags.

## Required scenarios

- contribution success, duplicate replay, and failure without debt;
- standing-order retry and recovery;
- withdrawal success and failure recovery;
- provider callback replay protection;
- reconciliation with exactly zero unexplained variance;
- servicing after acquisition is disabled.

The most recent attempt for each scenario must pass. `reconciliation_zero_variance` must record zero unexplained variance. Scenario evidence and lifecycle events are append-only.

## Runtime configuration

- `SAVINGS_PROVIDER_MODE`: `deterministic`, `sandbox`, or `live`. Production defaults to `live`; deterministic mode is rejected in production.
- `SAVINGS_PROVIDER_CODE`: non-secret provider identifier used by certification records.
- `SAVINGS_PROVIDER_ADAPTER_CODE`: adapter registered for that provider. It must equal `SAVINGS_PROVIDER_CODE`.
- `SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT`: lowercase SHA-256 fingerprint of the non-secret canonical configuration inventory; rotate it whenever credentials or account routing changes. Do not hash only a low-entropy secret.
- `SAVINGS_PROVIDER_JURISDICTION`: defaults to `NG`.
- `SAVINGS_PROVIDER_CURRENCY`: defaults to `NGN`.

No provider has yet been selected for savings/custody. Until an adapter, credentials, settlement configuration, webhook validation, and certification evidence exist, sandbox/live acquisition correctly fails closed. Deterministic workflows remain available outside production for automated testing.

## Incident and rollback

Disable `financial.savings.enrol`, `financial.savings.contribute`, and `financial.savings.accrue` to stop new exposure. Do not disable `financial.savings.read`, `financial.savings.withdraw`, or `financial.savings.service_existing`; they protect existing obligations. Preserve certifications, scenarios, events, journals, and reconciliation evidence. A changed provider configuration requires a new version and fingerprint rather than mutation of approved evidence.
