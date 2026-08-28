# Version 1 API and error conventions

These conventions apply to new endpoints and material changes under /api. Existing Version 1 fields remain compatible unless a migration plan is approved; breaking changes use a new API version.

## Transport and representation

- JSON requests use Content-Type: application/json; provider webhooks retain exact raw bytes until signature verification.
- Identifiers are opaque strings, normally UUIDs. Timestamps are UTC ISO 8601 strings.
- Money is returned as integer minor units with an explicit ISO currency code.
- Sensitive identifiers and financial destinations are masked. Secrets, tokens, OTPs, and raw provider payloads are never returned or logged.
- Every response carries x-correlation-id. A valid client UUID is preserved; otherwise the backend generates one.

## Success responses

New command and read endpoints use:

~~~json
{
  "success": true,
  "data": {},
  "meta": {}
}
~~~

meta is optional. Create commands return 201; successful reads and state transitions normally return 200; asynchronous acceptance returns 202; successful deletion without a body returns 204.

List endpoints use a deterministic order and bounded pagination. Cursor pagination is preferred for mutable datasets. Offset pagination must return the applied offset, limit, and total only when the count is safe and tenant-scoped.

## Error responses

The stable Version 1 error envelope is:

~~~json
{
  "success": false,
  "error": "Human-readable message",
  "code": "MACHINE_READABLE_CODE",
  "message": "Human-readable message",
  "correlationId": "123e4567-e89b-12d3-a456-426614174000",
  "details": {}
}
~~~

code, message, and correlationId are the contract. error is a backward-compatible alias retained through Version 1. details is optional, bounded, non-sensitive, and must not expose persistence or provider internals. Unexpected server failures return INTERNAL_SERVER_ERROR and a generic message.

Common status mapping:

| Status | Meaning | Default code |
|---:|---|---|
| 400 | malformed request or validation failure | BAD_REQUEST |
| 401 | missing or invalid authentication | AUTHENTICATION_REQUIRED |
| 403 | authenticated but unauthorized | FORBIDDEN |
| 404 | resource absent in the authorized scope | NOT_FOUND |
| 409 | state, version, idempotency, or maker-checker conflict | CONFLICT |
| 422 | semantically invalid command | VALIDATION_ERROR |
| 429 | rate limit exceeded | RATE_LIMITED |
| 500 | unexpected internal failure | INTERNAL_SERVER_ERROR |
| 503 | required dependency or safe authorization decision unavailable | SERVICE_UNAVAILABLE |

Domain-specific codes use uppercase snake case and remain stable once released. A 404 must not reveal whether a resource exists in another tenant.

## Authentication, tenancy, and commands

Authentication establishes the actor. Tenant middleware resolves organization membership and jurisdiction from server-owned data. Authorization and backend feature flags are enforced before domain mutation.

Financial and externally visible commands require an Idempotency-Key where specified. Reusing a key with a different request hash returns a conflict. Provider callbacks have separate signature, replay, and idempotency controls.

## Compatibility and testing

Additive response fields are compatible. Removing or changing field meaning, money units, identifiers, state names, or error codes is breaking. Deprecations require documentation, telemetry, and a replacement window.

API tests cover authentication, wrong tenant, wrong role, disabled flag, validation, stable error code, correlation ID, idempotency/replay, masking, and the successful contract. Operational runbooks record rollback and provider-degradation behavior.
