# Group Constitution and Offices Runbook

## Scope

GT-02A makes every newly created group a private draft. A group becomes publicly
active only after its initial constitution is effective and every required office
(`chair`, `secretary`, and `treasurer`) has an active appointment.

Existing groups retain service continuity under an immutable legacy-baseline
constitution. Their `group_governance_reviews` records require later
ratification and office-history remediation; the migration does not invent
historical office holders.

## Normal activation

1. Create the group draft under a verified organization.
2. Adopt the initial constitution with a unique `Idempotency-Key`.
3. Appoint active, paid group members to all required offices. One person may
   temporarily fill more than one office during bootstrap; later constitution
   amendments may impose stronger separation rules.
4. Read `governance-setup` and confirm constitution and office evidence.
5. Activate using the current lifecycle version and a new idempotency key.

Activation is atomic. It fails if the group is not a draft, the lifecycle version
is stale, the constitution is not effective, a required office is missing, or a
GT-01 legacy review remains open.

## Recovery and rollback

- Retrying the same command with the same idempotency key returns the original
  resource and does not duplicate evidence.
- Effective constitutions and office history are immutable outside the governance
  engine. Corrections use later appointments or proposal-backed amendments.
- Before production activation, rollback may remove this migration only when no
  post-migration group has adopted a constitution. After activation, preserve
  evidence and use compensating governance commands rather than deleting rows.
- Provider account provisioning remains separate and must not determine whether
  group creation succeeds.

## Follow-on boundaries

Constitution amendments, general proposals, voter snapshots, membership
invitations/discipline/appeals, delegations, and notification outbox delivery are
implemented in later approved GT increments. This bootstrap path cannot amend an
active constitution.
