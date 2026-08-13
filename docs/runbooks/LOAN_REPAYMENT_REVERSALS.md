# Loan Repayment Reversals

CRD-08 corrects a settled zero-interest loan repayment through a maker-checker workflow.
The original repayment and journal remain immutable. Approval posts an exact linked financial
journal reversal, marks the original journal reversed, and restores the contract receivable.

Proposals require a reason code, narrative, evidence references, correlation ID, and idempotency
key. The reviewer must be a different authorized tenant member. Rejection preserves the proposal
without financial mutation. Approval reopens a paid-off contract to its latest disclosed
delinquency state or active when no delinquency assessment applies.

Interest-bearing repayment reversal fails closed because CRD-06 may also have posted a separate
interest-recognition journal. A later increment must link and reverse both journals atomically.
No operator may edit repayment rows, journal lines, balances, or assessment evidence manually.
