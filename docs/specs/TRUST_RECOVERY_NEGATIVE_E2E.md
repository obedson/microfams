# Trust and Recovery Negative-Path E2E Contract

## Test boundary

The authoritative end-to-end contract runs against a clean PostgreSQL 16 database after the canonical migration chain. It calls the real security-definer trust and recovery RPCs, verifies persisted state and immutable evidence, and rolls the fixture back. Controller and frontend tests verify that the public HTTP and UI boundaries preserve the same safe failure semantics.

## Required negative paths

| Boundary | Rejection or invariant |
| --- | --- |
| Trust authority | Non-platform administrators cannot open cases. |
| Reviewer independence | A reviewer cannot review themselves, an unassigned reviewer cannot decide, and the original reviewer cannot decide an appeal. |
| Appeal authority | An unrelated user cannot appeal another subject's case. |
| Decision binding | A suspension cannot target a user or case that does not match the recorded decision. |
| Idempotency | Reusing a key with different request facts fails; an exact consumed-token retry returns the original appeal. |
| Recovery scope | A token cannot be issued for an unrelated case or for a resumed account. |
| Token lifecycle | Superseded, invalidated, expired, and consumed tokens cannot start another operation. |
| Evidence | Recovery events and trust decision evidence remain immutable. |
| Client isolation | `anon` and `authenticated` cannot execute recovery RPCs or read internal token state directly. |
| Public API | Malformed inputs fail before persistence; invalid and expired tokens share one non-enumerating response; unexpected failures expose no provider or database detail. |
| User interface | Invalid/expired links do not expose the appeal form; failed token use displays a generic retry-safe message. |

## CI execution

`backend/scripts/verify-clean-schema.sh` runs `backend/tests/schema/test-trust-recovery-negative-e2e.sql` on every pull request through the backend schema job. Unit/API and frontend component suites run in their existing CI jobs. No external vendor credentials or hosted database are required for this deterministic contract.