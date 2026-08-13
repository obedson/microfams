# Loan Write-offs

CRD-10 provides maker-checker principal write-off for defaulted zero-interest, zero-fee loans.
The proposal pins the outstanding principal, product write-off policy, reason, evidence, correlation,
and idempotency facts. Approval by a different authorized tenant member posts an exact balanced
journal: debit credit-loss expense and credit loan-principal receivable.

The original contract, schedule, repayments, delinquency assessments, and journals remain immutable.
Approval moves the application and contract to `written_off`; repayment and delinquency servicing then
fail closed. Any principal change after proposal invalidates approval and requires a fresh proposal.

Interest-bearing and fee-bearing write-offs are excluded until accrued-interest, fee, waiver, tax,
and loss-recognition rules are separately approved. Recovery after write-off is also excluded and must
use a later recovery workflow with explicit income or allowance accounting.
