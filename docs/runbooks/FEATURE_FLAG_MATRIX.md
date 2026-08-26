# V1 feature-flag matrix evidence

The release matrix is exercised by `backend/src/tests/featureFlagMatrix.test.ts` across default-disabled, tenant-enabled, unavailable storage, degraded-provider configuration, and emergency-stop states. Provider-dependent capabilities remain backend-gated. A missing flag configuration fails closed for new exposure; required servicing flags may follow their catalog failure mode. Run `npm test -- --runInBand src/tests/featureFlagMatrix.test.ts` in the backend package.
