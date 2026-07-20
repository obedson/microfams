# Inbound payments, refunds, reversals, and settlement

## Scope

This runbook covers the FC-05 and FC-06 provider-neutral inbound-payment engine. The engine records tenant-owned payment intents before external calls, verifies raw webhook bytes, posts balanced journals only after a matching provider confirmation, and services refunds, provider reversals, fees, settlement, recovery, and reconciliation independently from new-payment acquisition.

## Feature gates

- 'financial.payments.accept_new' controls new payment initialization.
- 'financial.payments.service_existing' controls verification and customer-requested servicing APIs.
- Webhook receipt, background recovery, refunds already accepted by a provider, reversals, and reconciliation must remain operational during acquisition disablement.
- 'integration.paystack.live' is required per tenant for live routing.
- Live routing also requires 'PAYSTACK_LIVE_APPROVAL_ID', 'PAYMENT_RECONCILIATION_CERTIFIED=true', and Paystack credentials.
- 'PAYMENT_PROVIDER_MODE' must be 'deterministic', 'sandbox', or 'live'. Deterministic mode is rejected in production.

## Credentials

No provider credentials are needed for deterministic CI. Paystack sandbox or live contract testing requires:

- 'PAYSTACK_SECRET_KEY';
- the matching provider webhook endpoint configured as '/api/webhooks/paystack';
- 'PAYSTACK_LIVE_APPROVAL_ID' for live mode; and
- reconciliation certification metadata before live acquisition is enabled.

Secrets belong in Codespaces or the deployment secret manager and must never be committed.

## Canonical lifecycle

1. The application validates the tenant-owned source and records a created payment with an immutable internal reference and idempotency key.
2. The configured adapter initializes the provider transaction.
3. A provider timeout leaves the payment processing; it never becomes a synthetic success.
4. Webhooks are signature-checked against the exact raw body, stored by immutable hash, acknowledged, and processed asynchronously.
5. Success requires exact tenant, provider, reference, amount, and currency agreement.
6. Success posts provider clearing debit and customer-funds liability credit in one atomic command.
7. Source fulfillment happens only after the financial posting succeeds and is safely retryable.
8. Partial and full refunds enforce cumulative limits and post compensating journals.
9. Provider reversals create immutable reversal records and compensating journals; the original payment and journal are not edited.
10. Settlements post net bank cash and provider fees against gross provider clearing.

## Recovery

- The minute job processes verified payment provider events in receipt order.
- The fifteen-minute job queries stale requires-action and processing payments using their original internal reference.
- Replaying initialization, confirmation, refund, event receipt, reversal, or settlement with the same request returns the original record.
- A changed replay is rejected.
- Rejected provider events retain their verified payload hash and rejection reason for investigation.

## Reconciliation

Inbound and outbound records use the same exact matching identity: provider reference, internal reference, currency, direction, amount, and approved date window. Amount-only matching is forbidden. Duplicate, late, mismatched, and unmatched items enter the existing exception queue. Daily close reports opening balance, signed movements, derived closing balance, provider balance, matched value, and unexplained variance.

## Incident actions

1. Disable 'financial.payments.accept_new' for the affected tenant and environment.
2. Keep webhook receipt and servicing active.
3. Inspect payment attempts, verified provider events, journals, refunds, reversals, settlements, and reconciliation exceptions by correlation and internal reference.
4. Query the provider using the existing reference; never create a second financial reference for an unknown result.
5. Resolve differences with evidence and an approved compensating entry. Never edit a posted journal.

## Rollback

Before deployment, the migration can be rolled back only when the new tables contain no durable financial records. After any journaled payment, refund, reversal, or settlement exists, do not drop the schema. Disable acquisition, continue servicing, deploy a forward corrective migration, and reconcile every affected provider and bank position.
