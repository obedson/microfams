# Savings accrual operations

SAV-03 calculates completed-day simple-interest accruals using immutable formula snapshots, then requires an independent approval before balanced accrued-return posting. Rejected batches remain evidence and must be recalculated with a new idempotency key after correction.

Disable new calculations or approvals with the savings accrual feature flag. Never edit accrual rows or journals manually; recover through rejection, recalculation, or compensating journal procedures.
