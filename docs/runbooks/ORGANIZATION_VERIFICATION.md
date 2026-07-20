# Organization verification operations

The organization-verification core supports deterministic development tests and provider-neutral production integration without storing raw registration numbers.

## Safe defaults

- `integration.organization_verification` defaults disabled.
- Outside production, `ORGANIZATION_VERIFICATION_PROVIDER=deterministic` may be used.
- Production fails closed until an approved provider adapter is configured.
- Existing verification status stays readable when submissions are disabled.

## Configuration

Deterministic tests require no credentials. Set `DETERMINISTIC_ORGANIZATION_VERIFICATION_OUTCOME` to `verified`, `review_required`, or `rejected` when a specific negative path is required.

Production requires:

- `ORGANIZATION_REGISTRATION_FINGERPRINT_KEY`
- `ORGANIZATION_VERIFICATION_PROVIDER`
- the selected provider environment, endpoint, client identifier, secret or certificate, and webhook/signature settings

No live organization-verification vendor has been selected. Do not enable the tenant flag until provider approval, credentials, privacy review, retention rules, and contract tests are complete.

## Incident and recovery

A provider-start error marks the request failed with a stable reason code and no raw payload. Retry with a new idempotency key after resolving the provider incident. Reusing a key with changed facts is rejected.

Do not edit requests or verified evidence. Revocation and manual review will use the subsequent audited trust-review workflow.

## Verification

Run in the Codespace:

```bash
cd /workspaces/microfams/backend
npm run typecheck
npm run test:unit
npm run test:schema
npm run test:schema:legacy
```
