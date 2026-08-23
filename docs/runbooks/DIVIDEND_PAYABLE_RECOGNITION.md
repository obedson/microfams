# Dividend payable recognition operations

DIV-03 recognizes an approved dividend as a payable through the canonical balanced journal function. The command is tenant scoped, period validated, account-purpose validated, idempotent, and protected by the accounting-post feature and permission gates. Payment remains a separate workflow.

Record the distribution, account IDs, effective date, idempotency key, correlation ID, actor, and returned journal ID. Disable new recognition through the accounting-post flag. Never edit the distribution or journal; recover through compensating journal and governed correction workflows.
