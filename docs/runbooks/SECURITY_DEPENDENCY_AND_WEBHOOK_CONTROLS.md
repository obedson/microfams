# Dependency and webhook security controls

This runbook records the current WP-P0-004 controls.

## Dependency review

Run in the Codespace:

```bash
npm --prefix backend audit --audit-level=high
npm --prefix frontend audit --audit-level=high
npm --prefix mobile audit --audit-level=high
npm --prefix mcp-servers audit --audit-level=high
```

A high or critical finding blocks release. Remediate through a reviewed lockfile update, rerun all CI suites, and confirm no unrelated dependency drift.

The mobile dependency tree pins Metro to patched release `0.84.5`; its high and critical
audit findings are clear, and its production audit is clean. The remaining moderate UUID
advisory is confined to Expo configuration tooling and requires a future Expo-compatible
upgrade. Frontend overrides clear all high and critical findings; two moderate
`webpack-dev-server` advisories remain confined to local development tooling. These
results were revalidated across all four package trees on 2026-08-28.

## Webhook controls

Provider adapters verify raw request bytes with constant-time comparison before parsing or mutating state. Payment, payout, refund, and investment-refund paths reject tampered signatures and carry idempotency/replay evidence.

- [x] Preserve the raw body before JSON parsing.
- [x] Verify the provider signature with constant-time comparison.
- [x] Enforce timestamp/replay protection where supported.
- [x] Check idempotency before mutation.
- [x] Keep duplicate, delayed, invalid, and out-of-order callbacks recoverable and auditable.
- [x] Never log secrets or full payloads.

## Incident and rollback

Disable the affected provider flag, stop new provider mutations, preserve evidence, rotate secrets in the deployment secret manager, deploy the reviewed fix, replay only verified events, reconcile, then re-enable.
