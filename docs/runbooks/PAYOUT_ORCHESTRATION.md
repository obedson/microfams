# Payout Orchestration and Reconciliation Runbook

## Scope

This runbook covers FC-05/FC-06 wallet payouts introduced by `create_payout_orchestration.sql`. The payout domain is provider-neutral and stores tenant-owned payout state separately from provider references and verified events. The financial journal remains the source of truth.

## Modes and activation

`PAYOUT_PROVIDER_MODE` selects `deterministic`, `sandbox`, or `live`.

- Deterministic mode is available only outside production and never represents test money as live money.
- Sandbox mode requires Interswitch client credentials and a webhook secret.
- Live mode additionally requires `INTERSWITCH_LIVE_APPROVAL_ID`, `PAYOUT_RECONCILIATION_CERTIFIED=true`, and the backend `integration.interswitch.live` feature flag for the tenant.
- New payout creation also requires `financial.wallets.transact` and `financial.payouts.create`.
- Callback processing and status recovery use `financial.payouts.service_existing`; disabling acquisition must not stop servicing existing obligations.

Required secret names are documented without values:

- `INTERSWITCH_CLIENT_ID`
- `INTERSWITCH_CLIENT_SECRET`
- `INTERSWITCH_WEBHOOK_SECRET`
- `INTERSWITCH_AUTH_URL`, `INTERSWITCH_API_URL`, and `INTERSWITCH_MARKETPLACE_URL` when non-default endpoints are required
- `INTERSWITCH_LIVE_APPROVAL_ID` for live routing
- `DETERMINISTIC_PAYOUT_WEBHOOK_SECRET` for local and CI callback contract tests

No provider credential is required for deterministic unit and schema tests.

## Workflow

1. The wallet service reserves available funds and consumes the reservation into the pending-payout liability.
2. `create_wallet_payout` creates one payout for the withdrawal and rejects changed replays.
3. The configured adapter submits the payout. A timeout or ambiguous response remains `processing`; it is never reported as success and does not create a new financial reference.
4. The provider calls `POST /api/webhooks/interswitch/payout`. The raw request bytes are signature-verified before a provider event is stored.
5. The webhook response acknowledges the durable event. A background job processes verified events and applies amount, currency, reference, tenant, provider, and environment checks.
6. Success moves the complete pending amount to provider clearing through a balanced journal. Failure restores the exact consumed reservation through a compensating journal.

Payout state transitions are database allowlisted. Direct writes to payouts, attempts, and provider events are rejected outside the payout engine.

## Recovery

### Submission remains processing

Do not initialize a second payout. Confirm the stored internal reference and provider/environment, then invoke the normal status-sync path or allow the hourly recovery job to query the adapter. A provider result must match the original amount and currency before it can become terminal.

### Verified event remains received

Inspect the structured job error without exposing the raw payload or destination account. Correct configuration or dependent state, then allow the minute job to retry the same `provider_events.id`. The raw-event hash prevents duplicate value creation.

### Failed payout restoration

Verify:

- payout state is `failed`;
- withdrawal state is `FAILED`;
- the reservation is `released` with a restoration journal;
- original plus restoration has zero net wallet effect;
- the provider did not later settle the transfer.

A late provider success after restoration is an incident and reconciliation exception; do not edit the original journal or payout row.

### Reconciliation exception

Matching requires provider reference, internal reference, currency, direction, amount, and the configured date window. Amount-only matching is forbidden. Resolve exceptions with a reason, actor, evidence reference, and compensating journal when required. Never delete or rewrite imported reconciliation evidence.

## Daily controls

For every provider/environment/currency configuration, record opening balance, movements, closing balance, provider balance, matched value, and unexplained variance. Live exposure remains disabled until certification scenarios produce zero unexplained variance.

## Rollback

Before live activation, rollback consists of disabling `financial.payouts.create` and the provider live flag while leaving servicing enabled. Do not drop payout or provider-event tables after any financial activity. Schema rollback after real activity requires an approved archival migration and a zero-variance reconciliation report.
