# DIV-01 dividend entitlement operations

The dividend entitlement workflow creates an immutable proportional paid-unit entitlement snapshot for one tenant and distribution. The snapshot records the eligibility date, paid units, member allocation, currency, withholding metadata, rounding method, and any disclosed residual. Entitlement calculation is separate from maker-checker review, payable recognition, and payment.

Operators monitor failed calculations, duplicate idempotency requests, stale source periods, and unexplained rounding residuals by correlation ID. Never edit an entitlement snapshot. Correct a bad calculation through a governed new distribution or compensating accounting workflow while preserving the original evidence.

## Rollback

Disable new dividend acquisition or calculation with the backend feature flag when required. Existing snapshots remain readable. Resume only after the source period, paid-unit totals, residual, and audit evidence reconcile exactly.
