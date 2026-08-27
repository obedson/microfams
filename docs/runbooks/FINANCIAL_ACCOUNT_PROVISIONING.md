# Financial Account Provisioning Operations

This runbook covers FC-02 canonical financial-account provisioning. Account purposes and ownership rules are defined by `financial_account_purpose_rules`; application roles must use the trusted `provision_financial_account` command and must not write account rows directly.

## Provisioning checklist

1. Confirm the organization, actor, accounting period, currency, owner type, owner identity, effective date, and approved account code/name.
2. Select a purpose from the canonical rules, such as `individual_wallet_funds`, `group_wallet_funds`, `pending_payout`, `escrow_funds_held`, `savings_principal`, `loan_principal_receivable`, `dividends_payable`, `investor_subscriptions_payable`, `investor_redemptions_payable`, `provider_clearing`, `settlement_receivable`, `platform_fee_revenue`, or `provider_processing_fee`.
3. Verify the purpose permits the requested owner type and that the actor has `financial.accounts.manage` in the target organization.
4. Use a unique idempotency key. Replaying the same key and facts returns the original account; reusing it with changed facts is rejected.
5. Confirm the resulting account is active for the intended organization, purpose, owner, currency, and effective date. Capture the organization audit event `FINANCIAL_ACCOUNT_PROVISIONED`.
6. Reconcile the account to its journal mapping before enabling a workflow that posts to it.

## Safety controls

Purpose rules, account rows, and provisioning evidence are protected from direct mutation by `anon`, `authenticated`, and the backend service role. Only the security-definer command can create an account. The unique active-purpose index prevents duplicate active accounts for the same organization, purpose, owner, and currency.

Never provision an account to bypass a missing journal mapping, tenant permission, provider certification, or product feature flag. Account creation does not enable a financial product or authorize posting.

## Rollback and recovery

Provisioning is additive and account records are not deleted to correct mistakes. If an account was provisioned incorrectly and has no postings, disable the related acquisition flag and raise a corrective command or approved migration review. If it has postings, preserve the account and evidence; correct the mapping with a new governed account or compensating journal according to the accounting runbook. Never edit posted journals or mutate the purpose rule table in production.

For incidents, record the organization, account ID, purpose, provisioning key, correlation ID, actor, reason, and reconciliation result. Re-enable dependent workflows only after the account and journal-derived balances reconcile with zero unexplained variance.
## Verification commands

```bash
npm --prefix backend run test:schema
node scripts/reconcile-v1.mjs --check
```

The schema suite verifies canonical purpose rules, allowed owner types, organization isolation, idempotent provisioning, changed-replay rejection, protected direct writes, and audit evidence. Record the tested commit and CI run before enabling a dependent financial workflow.
