# Loan Delinquency Servicing

CRD-07 assesses arrears for existing zero-fee loan contracts through the backend-enforced
`financial.loans.service_existing` flag and permission. The database serializes each contract,
derives due amounts from immutable installments and settled allocations, and selects the latest
ordered delinquency stage pinned to the application's approved product-rule snapshot.

Each assessment records its date, days past due, separated principal/interest/fee arrears,
classification, stage evidence, request hash, correlation ID, actor, and audit event. `late`
keeps the contract active; `delinquent` and `defaulted` move the contract and application into
their disclosed states. A later current assessment can return a previously delinquent contract to active.

This increment does not post penalties, collection costs, notices, default recovery, restructuring, or write-offs.
Fee-bearing contracts fail closed until approved fee allocation and repayment servicing exists.
Recovery is retry by idempotency key; assessment records are immutable and manual balance edits
are forbidden.

Operational checks:

- compare the assessment arrears with due installments and settled repayments before its date;
- verify the pinned stage, contract/application state, correlation ID, and audit event;
- retry failed commands with the same idempotency key and identical facts;
- disable new assessments using the servicing feature flag without hiding historical evidence.
