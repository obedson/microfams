# Backend Dependency Audit

The backend development toolchain now uses `tsx` 4.23.12, which resolves the patched `esbuild` 0.28.x line. `npm audit` reports zero vulnerabilities, and the production-only audit remains clean.

This is a dependency and lockfile change with no application schema migration. Roll back by redeploying the prior dependency lockfile only if the development/test toolchain regresses; production runtime dependencies were already unaffected by the advisory.
