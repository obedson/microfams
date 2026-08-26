# Dependency and webhook security controls

This runbook records the current WP-P0-004 controls.

## Dependency review

Run in the Codespace:

```bash
npm audit --omit=dev --audit-level=high
npm audit --audit-level=high
```

A high or critical finding blocks release. Remediate through a reviewed lockfile update, rerun all CI suites, and confirm no unrelated dependency drift.

## Webhook controls

Provider adapters verify raw request bytes with constant-time comparison before parsing or mutating state. Payment, payout, refund, and investment-refund paths reject tampered signatures and carry idempotency/replay evidence.

- [ ] Preserve the raw body before JSON parsing.
- [ ] Verify the provider signature with constant-time comparison.
- [ ] Enforce timestamp/replay protection where supported.
- [ ] Check idempotency before mutation.
- [ ] Keep duplicate, delayed, invalid, and out-of-order callbacks recoverable and auditable.
- [ ] Never log secrets or full payloads.

## Incident and rollback

Disable the affected provider flag, stop new provider mutations, preserve evidence, rotate secrets in the deployment secret manager, deploy the reviewed fix, replay only verified events, reconcile, then re-enable.
