# V1 Recovery Smoke Evidence

This deterministic release smoke contract exercises safe application recovery controls in CI without production credentials or destructive data operations.

## Covered controls

- Emergency disablement blocks new payment exposure and fails closed.
- Existing payment servicing remains enabled so callbacks, reconciliation, refunds, reversals, and recovery can continue.
- A failed pending payment remains retryable within the configured bound.
- A replay whose business facts changed is rejected rather than silently creating a second recovery attempt.

## Run

    cd backend
    npm test -- --runInBand src/tests/releaseRecoverySmoke.test.ts

The test uses an in-memory feature-flag repository and pure recovery eligibility logic. No hosted database, provider credential, personal data, or financial posting is touched.

## Operational rollback

If a release introduces unsafe new exposure, activate the backend emergency stop or disable the acquisition flag. Keep servicing flags enabled, preserve immutable records, and use compensating entries or forward migrations for corrections. After mitigation, rerun required CI checks on the exact release commit and attach the incident record to release notes.
