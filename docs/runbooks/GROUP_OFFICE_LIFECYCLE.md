# Group Office Lifecycle Runbook

## Scope

GT-02D services offices after group activation. Permanent appointments and
removals execute only from approved, closed proposals. Temporary delegation is
bounded by the effective constitution's office definition and retains the source
assignment, delegate assignment, authenticated actor, and correlation evidence.

## Proposal contracts

An `office_appointment` proposal uses:

```json
{"officeKey":"treasurer","memberId":"<group-member-uuid>","termEndsAt":"2027-08-01T00:00:00Z"}
```

An `office_removal` proposal uses:

```json
{"assignmentId":"<active-assignment-uuid>","reasonCode":"DUTY_BREACH"}
```

The affected member's user ID must be in `conflictUserIds` before the proposal is
opened. Execution fails closed if this conflict exclusion is missing, the
constitution changed, the member is no longer active and paid, the term violates
the office definition, or the proposed holder has an incompatible office.

## Execution and delegation

1. Close voting and confirm the proposal is `approved`.
2. Execute with the current proposal state version and a unique idempotency key.
3. Read `/offices/lifecycle` to confirm the current holder, vacancies, and history.
4. A current holder may delegate their office; a governance manager may service
   it on their behalf. Delegations cannot exceed the office maximum (30 days by
   default) or the source holder's remaining term.
5. End a delegation with a reason code. The source holder is reinstated only if
   their original term and active paid membership remain valid.
6. Run `service-expired` from the tenant scheduler. Expired active or delegated
   assignments become immutable history. A valid source holder resumes after a
   delegation expires; otherwise the read model reports the vacancy.

## Safety and recovery

All commands are tenant-bound and idempotent. Direct updates remain blocked by
the governance-evidence trigger. A failed command does not partly replace an
office because the proposal transition and assignment changes share one database
transaction. Retry the same command with the same idempotency key after a network
failure. Correct a wrong approved appointment through a later removal or
appointment proposal; never delete assignment or proposal evidence.

Constitution amendments and new office definitions are deliberately outside this
increment and must arrive through GT-03's separate versioned amendment executor.
