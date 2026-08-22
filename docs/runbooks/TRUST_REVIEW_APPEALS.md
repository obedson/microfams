# Trust Review and Appeals Operations

## Scope

This runbook covers review cases, independent appeals, organization and membership suspension, and retention dry-run planning. Global user suspension continues through the platform-administration runbook.

## Feature controls

All new operations default off and fail closed:

- `trust.review_cases` opens new cases.
- `trust.appeals` accepts new appeals.
- `trust.suspensions` applies new organization or membership suspensions.
- `trust.retention.dry_run` creates non-destructive retention plans.
- `trust.retention.execute` is reserved; the database provides no execution RPC and constrains destructive execution to false.

Disabling flags must not block status/history reads, appeal decisions already in progress, conflict declarations, or resume/recovery commands.

## Reviewer operations

1. Confirm an active platform-administrator assignment.
2. Open a case without raw NIN, BVN, OTP, bank details, provider payloads, or credentials.
3. Assign a reviewer who is not the subject and has no declared conflict.
4. Record a bounded reason code and rationale. Review decisions are immutable.
5. If appealed, ensure the appeal decision maker differs from the original reviewer. Never rewrite the original decision.

Every command requires an `Idempotency-Key`. Retrying the same request with the same key is safe; reusing a key with different facts is rejected.

## Suspension and recovery

- Organization suspension is platform-administrator-only.
- Membership suspension is allowed for a platform administrator or an active owner/admin in the same organization.
- The last active owner cannot be suspended.
- Resume commands remain available when the suspension feature flag is disabled.
- A membership cannot resume while its organization is suspended.
- Global account suspension always overrides tenant access.

If access is incorrectly restricted, inspect immutable case, decision, suspension, and event records; then use the matching resume or appeal workflow. Do not update history tables manually.

## Retention and legal holds

Retention runs are report-only. Confirm the policy version, organization scope, and legal holds before creating a dry run. Review `data_retention_run_items` for `held`, `excluded`, `would_anonymize`, and `would_delete` classifications. No source data is changed.

Every five minutes the retention selection worker claims planned dry runs and invokes the service-role `select_retention_dry_run_items` RPC. It records only aggregate success/failure in logs, continues processing independent runs after an error, and never executes destructive retention. Hold or policy lookup failures leave the run planned for retry.

Do not enable destructive retention. It requires a separately approved migration, privacy/legal approval, restore testing, and a new operational runbook. Financial ledgers and required audit evidence remain excluded from destructive deletion.

## Monitoring and incident response

Alert on repeated idempotency conflicts, cross-tenant denials, reviewer-conflict declarations, failed suspension projections, and unexpected feature-flag evaluation failures. Never log free-text evidence or identifiers.

For an incident:

1. Disable the relevant new-operation flag.
2. Keep reads, appeals already filed, and recovery paths available.
3. Preserve database and application audit evidence.
4. Correct with an appeal outcome, resume operation, or forward migration.
5. Record the incident and validate tenant isolation before re-enabling.

## Migration recovery

The migration is additive. Application rollback is performed by disabling the trust flags and deploying the prior service version. Do not drop trust tables or functions after they contain evidence. Schema defects require a forward migration. Before rollout, run clean-schema and legacy-upgrade checks; after rollout, verify feature definitions and service-role RPC access without exposing secret values.
