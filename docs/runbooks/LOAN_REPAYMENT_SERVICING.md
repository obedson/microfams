# Loan Repayment Servicing

CRD-06 records settled repayments for existing loan contracts through the
backend-enforced financial.loans.service_existing flag and permission.
Amounts are integer minor units. Tenant and actor identities come only from
authenticated request context.

The database serializes each contract, rejects overpayment, preserves request
hashes for replay, allocates in the accepted offer's disclosed order, posts a
balanced immutable journal, and marks the contract and application paid off
only when principal and contractual interest are both zero.

Statutory charges, collection costs, and penalties remain zero because their
governing servicing rules are not implemented in this increment. Fee-bearing
contracts fail closed because the approved five-bucket order does not specify
where contractual fees rank. No operator should bypass this guard; extend the
approved specification and migration before enabling those repayments.

Recovery is retry-by-idempotency-key. A failed transaction leaves no repayment
or journal entry. A successful replay returns the original repayment. Posted
records are immutable; corrections require a future approved reversal or
compensating-entry workflow.

Operational checks:

- verify the repayment, allocation snapshot, journal entry, and audit event;
- compare journal receivable balances with the returned outstanding amounts;
- investigate any rejected reconciliation or fee-allocation request rather
  than altering balances manually;
- disable new servicing with the backend feature flag when necessary without
  deleting or hiding historical records.
