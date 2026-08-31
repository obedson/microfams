# Identity verification

The identity domain verifies NIN or BVN ownership without storing the raw identity number.

## Controls

- The API requires authentication, active tenant membership, and the backend `integration.identity_verification` feature flag.
- Explicit versioned consent is recorded before provider contact.
- Raw NIN/BVN values exist only in process memory during provider submission.
- Persistence uses a platform-wide, evidence-type-separated HMAC fingerprint, masked OTP destination, provider reference, and encrypted opaque provider state.
- The provider phone must match the phone registered on the Micro Fams account; the OTP is sent only to that registered phone.
- OTP attempts are limited and audited. There is no development bypass in live adapters.
- A platform identity binding permits one user per NIN/BVN fingerprint while allowing that user to create separate tenant evidence in each organization.
- Validation creates tenant-scoped `financial_kyc_evidence` linked to the consent, request, provider environment, expiry, and regulatory context, allowing FC-07 to calculate the KYC tier.
- Existing `nin_verified` consumers remain compatible, but a new verification does not populate the legacy raw `nin_number` column.

## Configuration

Deterministic development and test execution requires no external credentials. It accepts the OTP configured by `DETERMINISTIC_IDENTITY_OTP`, defaulting to `123456` outside production.

Live or provider-sandbox execution requires:

- `IDENTITY_PROVIDER=interswitch`
- `IDENTITY_PROVIDER_ENVIRONMENT=sandbox` or `live`
- `IDENTITY_FINGERPRINT_KEY`
- `IDENTITY_DATA_ENCRYPTION_KEY` as a Base64-encoded 32-byte key
- the existing Interswitch client, secret, terminal, and URL configuration

The tenant feature flag must remain disabled until provider credentials, approval, privacy review, and retention rules are ready.

## Recovery

Provider-start failure marks the request failed without storing provider payloads. A client retries with a new idempotency key. Repeating the same key returns the existing request; changing its facts is rejected.

If confirmation fails, the attempt counter is incremented. Exhausted challenges are rejected. Never reset attempts or edit evidence manually.

A provider transport failure during confirmation returns a stable retry instruction and records `PROVIDER_CONFIRM_UNAVAILABLE` without consuming an OTP attempt or clearing the encrypted challenge. Retry the same request before `expires_at`; a later valid response completes through the normal atomic path. Provider error bodies, hosts, tokens, and stack details must not appear in API responses or logs. A provider outage before challenge creation marks the request failed and requires a new idempotency key.

The production identity job runs every minute. It claims one durable execution lease and expires up to 100 due `created` or `awaiting_otp` requests with a bounded, skip-locked transaction. Expiry clears encrypted provider challenge state, records `CHALLENGE_EXPIRED`, and appends one `expired` event. Replaying the same servicing window is a safe success and does not duplicate events.

Failed executions enter the durable job retry lifecycle and dead-letter after five attempts. Recover a dead-letter only after resolving the database or deployment fault; use the durable-job recovery procedure and rerun the normal scheduler. Do not edit request state, tokens, events, attempt counts, or job evidence manually. Logs contain aggregate counts and stable failure codes only, never provider references, challenge state, OTPs, fingerprints, or identity numbers.

Fingerprints created before the platform-wide binding migration cannot be compared across tenants because they were derived with tenant context. They remain valid tenant evidence, but cross-tenant portability requires a governed re-verification that creates the platform binding. Never attempt to reconstruct a raw NIN or BVN from historical evidence.

## Verification

Run in the Codespace:

```bash
cd /workspaces/microfams/backend
npm run typecheck
npm run test:unit
npm run test:schema
npm run test:schema:legacy
```
