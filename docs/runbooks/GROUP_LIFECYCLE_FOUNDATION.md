# Group lifecycle foundation

## Scope

GT-01A adds tenant keys to group memberships and legacy votes, permits users to
belong to multiple groups, restricts group APIs to verified organization context,
and records additive lifecycle and quarantine evidence.

Constitution activation, proposals, voting snapshots, and final governance
execution are intentionally reserved for the next approved GT increment.

## Quarantine

The migration opens a `group_legacy_reviews` item and suspends a legacy group when:

- its organization is suspended or closed;
- its creator is not an active member of its organization;
- a group member is not an active member of the owning organization; or
- legacy active state conflicts with canonical lifecycle state.

Do not repair these rows with direct SQL. Confirm tenant ownership and membership
evidence, then use the separately reviewed resolution workflow when available.

## Lifecycle incidents

Lifecycle state and `is_active` are protected derived fields. Use
`transition_group_lifecycle` with an expected version and correlation identifier.
The command supports active/suspended/closing/closed transitions, rejects stale
versions, and prevents reactivation while an open legacy review exists.

If lifecycle execution fails:

1. keep the current state unchanged;
2. inspect the correlation identifier and open legacy reviews;
3. correct membership or tenant evidence through an approved command;
4. retry with the current lifecycle version; and
5. never edit lifecycle events or derived fields directly.
