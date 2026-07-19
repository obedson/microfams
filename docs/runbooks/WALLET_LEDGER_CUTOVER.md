# Wallet ledger cutover runbook

## Scope

This runbook covers FC-08 wallet opening balances and the journal-backed posting engine. Migrations install the capability but never activate an organization automatically. Non-cutover organizations continue to use the legacy wallet RPC behavior.

## Before activation

1. Confirm organization ownership, memberships, and the current accounting period.
2. Run `audit_wallet_ledger_cutover(organization_id, actor_id)` repeatedly until the latest run is `ready`, has no anomalies, and its wallet, group, transaction, and amount controls match the signed review evidence.
3. Keep `financial.wallets.transact` and `financial.accounting.post` disabled for public acquisition until the tenant configuration, permissions, and operational approvals are ready.
4. Activate only through `activate_wallet_ledger_cutover(organization_id, migration_run_id, actor_id)` using the backend service role and an authorized tenant owner, administrator, or finance manager.
5. Reconcile every migrated wallet and group cache to its liability account before enabling transaction routes.

Activation posts balanced opening journals and makes `user_wallets.balance` and `groups.group_fund_balance` read-only outside the posting engine.

## Supported post-cutover movements

- confirmed group funding: provider clearing asset to group-wallet liability;
- user-to-user transfer: sender wallet liability to recipient wallet liability;
- group-to-user transfer: group-wallet liability to recipient wallet liability;
- withdrawal reservation: user-wallet liability to that wallet's pending-payout liability; and
- failed withdrawal restoration: the same pending-payout liability back to the user-wallet liability.

Every command uses a tenant-scoped idempotency key, posts a balanced journal, links append-only `wallet_transactions` evidence, and rebuilds affected caches in the same database transaction.

## Fund reservations and API money

Wallet command APIs accept `amountMinor`, `currency`, and an idempotency key. They do not accept or return floating-point financial amounts. Legacy decimal columns remain compatibility caches only; application adapters convert them through exact decimal strings.

Withdrawal confirmation creates an expiring `fund_reservations` record before any provider call. An active reservation reduces available balance without changing ledger balance. Consumption atomically moves the wallet liability to that wallet's pending-payout liability, and provider failure restores the exact consumed reservation through a compensating journal. Replays return the original reservation and journals.

The hourly wallet recovery job expires abandoned active reservations. Reservation rows are tenant-scoped and can only be mutated by the security-definer reservation engine, even though the backend service role has general table privileges.

Booking settlement and grace-period penalty deductions intentionally fail for active cutovers until their cross-organization settlement, fee, and revenue mappings are approved. Do not bypass these failures with direct cache writes.

## Rollback and recovery

`rollback_wallet_ledger_cutover(organization_id, actor_id)` is allowed only before operational wallet journals touch the migrated liability accounts. It posts complete reversal journals for opening balances and restores legacy cache writes. A corrected readiness audit can then be activated as a new run.

Once operational activity exists, rollback is intentionally rejected. For an incident after that boundary:

1. disable new wallet and payout acquisition through backend feature flags;
2. preserve callbacks and servicing required to resolve pending obligations;
3. identify affected commands by organization, correlation ID, source record, and idempotency key;
4. use linked reversals or approved compensating journals—never edit posted journals, evidence rows, or caches;
5. reconcile liability accounts, pending-payout accounts, provider clearing, legacy evidence, and derived caches; and
6. record the incident, actor, evidence, variance, and approval before re-enabling acquisition.

An organization is healthy only when every wallet/group cache equals its journal-derived liability balance, every operational journal balances, and no unexplained provider or settlement variance remains.
