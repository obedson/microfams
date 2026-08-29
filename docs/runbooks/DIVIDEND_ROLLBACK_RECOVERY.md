# Dividend rollback and recovery

Dividend and profit-sharing payment operations are monitored by correlation ID and reconciled against immutable payable and payment journals. If a distribution or payment incident occurs, disable only new dividend payment exposure through the backend feature flag. Existing posted records remain readable and are serviced through approved recovery commands.

Rollback uses compensating journals or governed reversal commands. Operators preserve the original entitlement, approval, withholding, payable, payment, idempotency, and audit evidence. Re-enable the workflow only after reconciliation confirms zero unexplained variance and the incident owner records recovery evidence.
