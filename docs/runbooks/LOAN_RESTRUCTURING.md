# Loan Restructuring

CRD-09 provides maker-checker restructuring for an outstanding zero-interest, zero-fee loan.
The proposal records the complete prior due-installment evidence and a deterministic replacement
schedule. The original contract, schedule, repayments, and journals remain immutable.

Approval requires a different authorized tenant member. It replaces only unpaid operational due
rows, creates new due rows linked to immutable restructuring installments, keeps the contract
serviceable, and records `restructured` on the application. Paid history is never rewritten. Rejection
records the review evidence without changing servicing state.

The outstanding principal must be unchanged between proposal and approval. Any intervening
repayment makes the approval fail closed so an operator must reject and create a fresh proposal.
Interest- or fee-bearing restructuring is excluded until revised pricing, recognition, disclosure,
and borrower re-acceptance rules are approved. Write-off is a separate loss-accounting workflow.
Direct table mutation is prohibited; recovery uses a new evidenced proposal and decision.
