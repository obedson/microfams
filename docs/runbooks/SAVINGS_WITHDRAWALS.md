# Savings withdrawals

SAV-04 requests are maker-checker, tenant-scoped withdrawals from savings liability accounts into the member's personal wallet. Approval is idempotent and posts one balanced journal entry; rejection and cancellation release the pending reservation without mutating posted journals.

The member workflow is available at /savings/withdrawals. Disable financial.savings.withdraw to stop new requests while retaining read-only evidence. Retry commands with the original idempotency key and correlation ID; never edit withdrawal or journal rows manually. Correct settled errors only through approved reversal or compensating journal workflows.
