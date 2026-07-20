# Financial rules and risk controls

This runbook covers FC-07 controls for new financial exposure. Provider feature flags remain the final switch for live routing; policy approval does not enable a provider.

## Safety model

- All money is an integer in minor units.
- Every approved or denied command creates an immutable, idempotent compliance snapshot.
- Approved snapshots retain the exact rule version and evaluated KYC tier.
- Tenant rules take precedence over platform test defaults.
- Platform or tenant maximums may be lower than a provider or regulatory ceiling, never higher.
- Holds, freezes, sanctions matches, and manual-review controls block new exposure.
- Servicing, correction, reversal, reconciliation, and recovery commands do not call the acquisition boundary and remain available.
- BVN/NIN values are never stored here. Only provider evidence references and validation state are retained.
- Beneficiary identity is represented by a SHA-256 fingerprint; logs and snapshots do not contain bank account numbers.

## Test defaults

The migration installs configurable platform test policies:

| Product | Channel | Minimum | Rolling 24-hour maximum |
| --- | --- | ---: | ---: |
| Wallet | P2P | NGN 100 | NGN 50,000 |
| Wallet | Withdrawal | NGN 1,000 | NGN 100,000 |

These values are test policy, not statements of Nigerian law. Payment and payout test rules use a high technical ceiling so deterministic adapters can be exercised; live provider feature flags remain disabled by default.

## Rule release

1. Create a draft rule version and its limits with the service-role administration path.
2. Include jurisdiction, product, channel, currency, effective window, KYC tier, regulatory source, and change reason.
3. Call `submit_financial_rule` as an actor with `financial.rules.propose`.
4. A different actor with `financial.rules.approve` calls `decide_financial_rule`.
5. Confirm the active effective window before enabling an acquisition feature flag.

The database rejects self-approval and any configured maximum above its recorded provider/regulatory ceiling. Active rule content is immutable; publish a new version for changes.

## KYC evidence

Record electronically validated BVN or NIN evidence in `financial_kyc_evidence` using only a provider reference. One current evidence type yields tier 1; both distinct types yield tier 2. Rejected, expired, or revoked evidence does not contribute to the tier.

## Risk response

Use `place_financial_risk_control` with a tenant, subject, product, reason code, and optional expiry. Use `release_financial_risk_control` to release it; release history is retained. Never delete a control to unblock a user.

If the policy service or database is unavailable, new exposure fails closed. Do not bypass the policy call. Continue provider-event ingestion and servicing jobs, then retry the original idempotent command after recovery.

## Live activation

Call `request_financial_live_activation` only after recording the licensed provider, compliance owner, approval evidence reference, jurisdiction, KYC rules reference, regulatory source and effective date. A different authorized actor calls `decide_financial_live_activation`. The relevant backend provider feature flag must still be enabled separately.

## Verification

Run in the Codespace:

```bash
cd /workspaces/microfams/backend
npm run typecheck
npm run test:unit
npm run test:schema
npm run test:schema:legacy
```

The schema suite verifies maker-checker separation, immutability, idempotency, rolling limits, risk blocking, and tenant isolation.
