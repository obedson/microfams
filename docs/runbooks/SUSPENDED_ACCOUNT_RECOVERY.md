# Suspended Account Recovery Runbook

## Enablement prerequisites

1. Apply `create_suspended_account_recovery.sql` after the trust-review migration.
2. Configure `BREVO_API_KEY`, `FROM_EMAIL`, and `FRONTEND_URL` in the deployment secret manager.
3. Confirm sender/domain verification and delivery in the provider sandbox.
4. Enable `trust.suspensions` and `trust.suspended_account_recovery` only in the intended environment.
5. Create, assign, and decide a user trust case with outcome `suspend_user`; suspend through the idempotent admin endpoint using that case ID.

## Smoke test

- Request recovery with an eligible suspended account and confirm the public response does not disclose eligibility.
- Confirm the received link opens `/trust/recovery`, grants no normal application access, and expires after 15 minutes.
- Submit an appeal and confirm a retry with the same idempotency key returns the same appeal.
- Confirm the token cannot be inspected or used for a different command afterward.
- Confirm a different/newer token invalidates the prior unused token.

## Failure handling

- Provider delivery failure invalidates the issued token; retrying the public request may issue a new one.
- Disable `trust.suspended_account_recovery` to stop public recovery operations. Existing filed appeals remain available to administrators.
- Resume an account through the normal audited admin command after an overturned/modified appeal; do not edit prior suspension or decision evidence.
- Never request or log a raw recovery token. Investigate using token IDs and event records only.

## Monitoring

Monitor request rate-limit responses, provider failures, issued-to-consumed conversion, expired-token errors, appeal backlog, and repeated requests. Alert on unusual issuance volume or repeated invalid-token attempts without storing raw IP addresses or token material in trust audit records.