# Suspended Account Recovery and Appeals

A globally suspended user may receive a single-purpose link through a verified account channel. It does not authenticate the user and cannot access profile, tenant, financial, marketplace, or farm data. It can only inspect the linked suspension state and file one appeal against the linked `suspend_user` decision.

## Security rules

- Tokens contain 256 bits of cryptographic randomness; only a SHA-256 digest is stored.
- Tokens expire after 15 minutes, are single-use, and a newer token invalidates prior unused tokens.
- Issuance requires an active account suspension and a decided user trust case with outcome `suspend_user`.
- Inspection and consumption re-check that the account remains suspended.
- Submission consumes the token atomically and is idempotent for safe retries.
- Token and event tables deny `anon` and `authenticated`; only service-role functions operate on them.
- Recovery request responses do not reveal whether an account exists, is suspended, or delivery succeeded.

## Delivery and feature controls

`trust.suspended_account_recovery` defaults off. Email is the first verified-channel adapter; SMS can implement the same contract after vendor selection. Delivery failure invalidates the issued token. Public endpoints are rate limited. Disabling the flag prevents issuance, inspection, and submission without deleting history or blocking administrators from resolving filed appeals.

## Audit and credentials

Issued, inspected, consumed, and invalidated events are append-only. Raw tokens, destinations, IP addresses, identity numbers, and provider credentials are excluded from audit records and logs. Real email testing requires `BREVO_API_KEY`, `FROM_EMAIL`, and `FRONTEND_URL` Codespaces secrets; deterministic tests use an in-memory delivery adapter.