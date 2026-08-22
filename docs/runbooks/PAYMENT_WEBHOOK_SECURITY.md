# Payment Webhook Security

## Active Path

Provider callbacks enter through `/api/webhooks`, which is mounted before JSON parsing and receives `application/json` as raw bytes. Payment and payout domain services verify the exact payload bytes before parsing or mutation and enforce replay/idempotency controls.

The removed legacy Paystack controller must not be restored: it reserialized parsed JSON and used a direct string signature comparison outside the provider-neutral payment engine.

## Deployment And Rollback

This is a code-only cleanup with no schema change. Verify raw-body callback contract tests and provider sandbox callbacks after deployment. Roll back by redeploying the preceding backend revision only if an unrelated import regression is discovered; do not route traffic through the legacy controller.
