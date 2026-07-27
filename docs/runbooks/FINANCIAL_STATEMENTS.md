# Financial Statements

## Scope

Personal and group wallet statements are derived only from tenant-owned financial accounts and posted journal lines. Legacy `wallet_transactions` and mutable wallet balance caches are not statement sources.

Reads require an authenticated active tenant context and the backend `financial.accounting.read` flag. A personal statement is available only to its account owner. A group statement additionally requires active membership in that group and organization. The database function is executable only by the backend service role.

## Reproducibility and pagination

Each request records an ISO cutoff timestamp. Only journals posted at or before that cutoff are included. The effective-date range determines the opening balance, period movements, and closing balance. Ordering is deterministic by effective date, posting time, journal line number, and line identifier.

The opening and closing balances cover the full requested period. A paginated page carries forward all preceding movements in the period, so every displayed running balance remains correct independently of page size.

## Feature disablement and recovery

`financial.accounting.read` controls statement access independently of transaction-creation flags. Disabling new wallet, payment, payout, or journal exposure does not invalidate existing journals.

If statement totals appear inconsistent:

1. preserve the request organization, owner type, owner identifier, date range, and cutoff without collecting bank or identity details;
2. compare the account's posted journal lines at the same cutoff;
3. verify journal ordering and the account normal side;
4. run the clean-schema financial statement contract;
5. correct financial history only through an approved reversal or compensating journal.

The statement function and API are read-only. Rollback consists of removing the API routes and reverting the migration function; no financial records are mutated.
