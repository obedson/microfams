# Group Committees and Meetings Runbook

## Scope

GT-09 services committees and meetings after group activation. A committee
mandate — creation, dissolution, or any change to delegated permissions or the
spending ceiling — is a governance decision and executes only from an approved,
closed `committee_mandate` proposal. Servicing inside an approved mandate
(membership changes, meeting scheduling, attendance, minutes) remains direct
and tenant-bound.

## Committee mandates

A `committee_mandate` proposal carries an action payload:

- `create`: `committee_key`, `display_name`, `mandate`,
  `delegated_permissions`, `spending_ceiling_minor_units`,
  `spending_ceiling_currency`, `reporting_duties`, `term_ends_at`.
- `amend`: `committee_id`, `delegated_permissions`,
  `spending_ceiling_minor_units`, `spending_ceiling_currency`.
- `dissolve`: `committee_id`, `reason_code`.

Only four permissions are delegable to a committee
(`groups.committee.recommend`, `groups.committee.report`,
`groups.meeting.schedule`, `groups.meeting.minute`). Anything that moves money
or decides governance stays on the GT-03 proposal path. Execution fails closed
if the permission list contains anything else, if the proposal is not `approved`
or the version is stale, or if the constitution changed.

A committee records its `mandate_proposal_id`, so it is always traceable to the
vote that authorised it.

## Committees and membership

1. Close voting and confirm the proposal is `approved`.
2. Execute with the current proposal state version and a unique idempotency key.
3. Read `/committees` for an overview with current membership.
4. A committee has at most one sitting chair and no duplicate sitting member.
   End a membership with a reason code; dissolution closes all open
   memberships in the same transaction.

## Meetings and minutes

1. Schedule with notice lead time, agenda, and a quorum fraction. Only an
   `emergency` meeting may shorten the notice window, and it must state why.
   The eligible-attendee count is snapshotted at scheduling so later
   membership changes cannot retroactively alter whether a held meeting met
   quorum.
2. Record attendance before holding. Attendance is presence only and never a
   financial approval.
3. Hold with the meeting's current state version; quorum is evaluated against
   the snapshot.
4. Draft minutes after the meeting is held. A draft may be edited in place.
5. Approve minutes to make them immutable. Corrections to approved minutes
   arrive as a linked `addendum`; the original is never rewritten.

## Safety and recovery

All commands are tenant-bound and idempotent. Direct updates are blocked by the
governance-evidence trigger. A failed command does not partly change a
committee or meeting because the proposal transition and the record changes
share one database transaction. Retry the same command with the same
idempotency key after a network failure. Correct a wrong approved mandate
through a later `amend` or `dissolve` proposal; never delete evidence rows.
