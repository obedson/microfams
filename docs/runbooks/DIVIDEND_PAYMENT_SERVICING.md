# Dividend payment servicing operations

DIV-04 credits each immutable entitlement to its active internal wallet using the canonical balanced journal function. The command is tenant scoped, payment-date and accounting-period validated, exactly-once, and records all journal IDs. External provider payout remains separate.

Record the distribution, effective date, correlation ID, actor, and returned journal IDs. Disable new payment servicing with the existing-dividend servicing feature flag. Never edit wallet or distribution rows; recover through compensating journals and governed correction workflows.
