# Trust Review, Appeals, Suspension, and Retention Core

## Purpose

This increment provides an auditable, tenant-aware trust process for Micro Fams. It covers review cases, independent appeals, decision-backed organization and membership suspensions, and retention planning. It does not permit destructive retention.

## Authority and isolation

- Platform trust actions run only through service-role RPCs. Review, appeal-decision,
  organization-suspension, and retention-planning actions require an active platform
  administrator. Membership suspension and resumption also permit an active owner or
  administrator of the membership's organization.
- A subject may appeal a decision affecting their user account or membership. An active organization owner or administrator may appeal a case in that organization.
- Tables use row-level security with no direct `anon` or `authenticated` access. Application APIs must expose only authorized, tenant-filtered projections.
- Case, decision, appeal, conflict, suspension, and retention activity is attributable and time stamped.

## Review lifecycle

1. An administrator opens a case for a user, organization, membership, transaction, content item, or other UUID-addressed subject.
2. An active administrator is assigned. A reviewer cannot review themselves or their own membership.
3. A reviewer declares any self, relationship, financial-interest, prior-involvement, or other conflict. Declaration removes the assignment and permanently prevents reassignment of that reviewer.
4. Only the assigned, conflict-free reviewer may record one immutable decision.
5. Outcomes are: no action, warning, suspend membership, suspend organization, suspend user, or refer.
6. Material events are append-only. Case status is mutable only to express lifecycle progression.

Every write command uses an actor-scoped idempotency key and SHA-256 request hash. Repeating the same facts returns the prior result; key reuse with different facts fails.

## Appeals

- Appeals require meaningful grounds and may be filed once per appellant and case after a decision.
- The appeal reviewer must be an active platform administrator, cannot be the appellant, and cannot be the original decision maker.
- Appeal outcomes are upheld, modified, overturned, or dismissed. Outcome rationale and a structured reason code are mandatory.
- The original decision remains immutable. An appeal records a new outcome and closes the review case; application services must use the appeal outcome when determining current effect.

## Suspension lifecycle

- Organization and membership suspensions require a matching review decision and case.
- Membership suspension and resumption may be performed by a platform administrator
  or an active organization owner/administrator in the matching tenant. Cross-tenant
  actors are denied without disclosing whether the target membership exists.
- Organization suspension and resumption remain restricted to platform administrators.
- Only one active suspension may exist for each organization or membership.
- Suspending an organization changes its operational status to `suspended`; lifting restores `active`.
- Suspending a membership changes it to `suspended`; lifting restores `active`.
- The last active owner of an organization cannot be suspended.
- A membership cannot resume while its organization is suspended.
- Suspension history is retained; lifting records actor, timestamp, and reason.
- User suspension continues to use the platform-administration workflow introduced earlier.

## Retention and legal holds

- Retention policies are versioned by organization scope and data class.
- Legal holds identify protected subjects and have explicit placement/release histories.
- Retention runs are permanently constrained to `dry_run`.
- Run items can only describe `retain`, `held`, `excluded`, `would_anonymize`, or `would_delete`; `executed` is constrained to false.
- Policy `destructive_enabled` is constrained to false.
- No RPC exists to delete or anonymize source records. Enabling the `trust.retention.execute` feature flag cannot bypass database constraints.
- A future destructive-retention increment requires separate approval, legal-hold evaluation, restore tests, operational runbooks, and a new migration.

## Feature controls

Backend flags default off and fail closed:

- `trust.review_cases`
- `trust.appeals`
- `trust.suspensions`
- `trust.retention.dry_run`
- `trust.retention.execute` (reserved and deliberately non-functional)

Disabling a flag prevents new API operations but does not hide existing history.

## Security and audit invariants

- Direct client table access is revoked.
- Decision, conflict, event, retention-item, and idempotency evidence is append-only.
- Structured reason codes use uppercase machine-readable values.
- Free-text rationale is length bounded and must not contain raw identity numbers, bank details, secrets, provider tokens, or unnecessary personal data.
- Database constraints protect state shape even if an application bug bypasses normal services.

## Recovery

Schema rollback must not delete recorded trust history. A service rollback disables the feature flags and retains read-only administrative access. Operational corrections use new appeal, lift, or compensating records rather than changing prior evidence.
## Deliberate follow-up boundaries

This core does not claim the full Phase 2 task complete. Before enabling user-level suspension in production, a short-lived single-purpose recovery/appeal token must be delivered to a verified account channel so a globally suspended user can appeal without receiving product access. Legal-hold placement/release commands and the retention item-selection worker also require a follow-up increment; the current database structures preserve those future invariants and retention remains dry-run-only.
