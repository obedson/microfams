# Legacy Handler Cleanup

The old direct Paystack payment controller and the incomplete authentication route were unreferenced and are removed. Runtime traffic uses the current payment orchestration and authenticated rate-limited auth routes.

This is a code-only cleanup with no migration. Verify backend typecheck and unit tests after deployment. Roll back by redeploying the prior revision only if an import or packaging regression is found; do not restore either legacy handler to production routing.
