# Group Member Discipline and Appeals

GT-02C replaces direct suspension and expulsion with a tenant-bound due-process workflow. A discipline case issues a public notice, preserves private evidence references, gives the member at least 24 hours to respond, and creates a linked draft `membership_action` proposal. The target member is recorded as conflicted and excluded from the immutable voter snapshot.

## Workflow

1. An authorized group or organization manager creates a case with `POST /api/group-admin/:groupId/members/:membershipId/discipline-cases` and an `Idempotency-Key`.
2. After `responseDueAt`, the existing proposal API opens the linked proposal. The constitution snapshot controls quorum and the special discipline threshold.
3. Eligible members vote through the proposal API. The target cannot vote. When the proposal closes approved, an authorized manager executes the case with the current membership `stateVersion`.
4. Execution changes only canonical membership state and active member count. It does not erase balances, contributions, claims, journals, or audit history.
5. The disciplined member may file one appeal before `appealDeadline`. Appeal filing remains available even if membership-acquisition feature flags are later disabled.
6. An active organization owner, administrator, or holder of `groups.membership.appeals.decide` may decide the appeal only if they were not the target, initiator, executor, proposer, or an approving voter in the original decision.

## Feature flags and servicing

New case creation and execution require `groups.membership.manage`. Proposal acquisition uses `groups.governance.manage`. Reads, appeal filing, and appeal decisions deliberately do not use acquisition flags because existing cases and appeal rights must remain serviceable.

## Operational checks

- Treat evidence references as pointers to access-controlled storage; never place credentials or raw secrets in them.
- Investigate `GROUP_MEMBERSHIP_VERSION_CONFLICT` before retrying execution. Fetch the membership and use its current version only after confirming the approved decision still applies.
- A `GROUP_DISCIPLINE_APPEAL_REVIEWER_CONFLICT` is a policy result, not a transient failure. Assign an independent reviewer.
- Every command is idempotent within its tenant and emits immutable discipline, membership, and proposal evidence.
- Legacy contribution auto-suspension, auto-expulsion, and direct member-action vote routes are intentionally removed. Missed payments may create evidence or a proposed case, but cannot change membership status directly.

## Verification

Run `bash backend/scripts/verify-clean-schema.sh` for the complete database workflow, including notice timing, conflict exclusion, approval, conservative execution, appeal independence, reinstatement, idempotency, and cross-tenant denial. Run the backend group discipline rule/API tests and the frontend discipline form test for boundary and presentation coverage.
