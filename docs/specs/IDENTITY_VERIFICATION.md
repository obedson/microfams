# V1 Identity Verification Contract

Status: Approved by the product owner on 2026-08-31.

## IV-01 Provider-neutral verification

NIN and BVN verification use a provider-neutral application contract. Deterministic, sandbox, and live adapters implement the same challenge and confirmation behavior. Provider-specific payloads remain inside adapters.

## IV-02 Consent and registered-phone possession

Verification requires explicit versioned consent before provider contact. The identity provider phone must match the phone registered on the Micro Fams user account, and the OTP is sent only to that registered phone. A client cannot supply a replacement OTP destination.

## IV-03 Data minimization

Raw NIN and BVN values exist only in process memory for provider submission. Raw identity numbers and provider-returned identity profiles are never persisted, logged, returned in verification responses, or placed in idempotency facts. Provider challenge state is encrypted and response destinations are masked.

## IV-04 Platform ownership binding

The backend derives an evidence-type-separated HMAC fingerprint from `evidence_type + ':' + identifier` using a platform secret. The organization identifier is not part of the fingerprint. An append-only platform binding enforces one fingerprint per user and one identity of each evidence type per user. A fingerprint already bound to a different user must be rejected atomically after provider confirmation.

## IV-05 Tenant evidence

The same bound user may verify in multiple organizations. Each organization receives separate consent, verification request, verified identity, and financial KYC evidence. Tenant evidence records the provider and environment, consent, status, expiry when supplied, and regulatory context without exposing the platform binding to tenant clients.

## IV-06 Legacy compatibility

Successful NIN verification may set `users.nin_verified = true` for existing authorization gates. It must not populate `users.nin_number` or any other raw provider identity field.

## IV-07 Atomicity and recovery

Platform binding, tenant evidence, financial KYC evidence, request completion, compatibility state, and audit event creation occur in one database transaction. Completion is idempotent. A conflict or failed evidence write rolls back the entire completion. Historical tenant-derived fingerprints remain tenant evidence but require governed re-verification before cross-tenant portability.

## IV-08 Degraded-provider recovery

A provider transport failure before challenge creation terminates that request with a stable reason and requires a new idempotency key. A transient provider failure during OTP confirmation preserves the active challenge, does not consume an OTP attempt, records a tenant-scoped deferred event, and permits confirmation retry until expiry. Provider error details must not be returned or logged.
