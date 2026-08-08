# Group Contribution Cycles Runbook

## Scope

GT-05 turns an effective GT-04 contribution rule into a dated billing cycle:
obligations per member, collection against those obligations, and a close that
lands the result in a named accounting period. A cycle is the only structure
that may declare a member in arrears, so every arrears figure in the product
traces to one closed cycle row rather than to a query written at read time.

## Lifecycle

```
draft -> open -> grace -> closing -> closed
           \_______________/
      (either state may enter closing)

draft | open | grace -> cancelled
```

`open` moves `draft` to `open` and materialises one obligation per active, paid
member from the rule version effective at the cycle's `due_at`. That version is
pinned onto the cycle: a later supersede cannot change what a member already
owes. `grace` is the post-due window that still accepts collection without
marking obligations overdue. Only `open` may enter `grace`; both `open` and
`grace` may enter `closing`. Any other transition is refused with
`GROUP_CONTRIBUTION_CYCLE_TRANSITION_INVALID`.

Cancellation is available until the cycle is `closed` or `cancelled`, but is
refused once any settlement exists against it
(`GROUP_CONTRIBUTION_CYCLE_HAS_COLLECTIONS`) — cancelling after money arrives
would orphan captured payments.

Obligations run `open -> satisfied | excess | waived | overdue | written_off`.

## Obligation adjustments

Adjustments are recorded as signed deltas against the original amount, never as
edits to it. Each carries one of four kinds — `waiver`, `reduction`,
`correction`, `write_off`:

```json
{"adjustmentKind":"waiver","delta":-250000,"reasonCode":"HARDSHIP_WAIVER","reason":"Approved at 2026-07 general meeting","evidenceUrl":"https://..."}
```

A zero delta is refused — it would write an evidence row asserting nothing. The
cumulative adjustment may not push an obligation below zero. A full waiver to
exactly zero is permitted; that is the intended way to excuse a member without
deleting the obligation record.

## Closing

Close refuses while any obligation is unreconciled, unless the caller passes
`acknowledgeExceptions: true`, which records the exception list as evidence
against the closing actor. Close also requires an open accounting period
covering `due_at`; a cycle cannot be closed into a locked period, and a missing
period is a configuration error rather than a cycle error. Both refusals return
409 with the engine's code.

## Safety and recovery

Every command is idempotent on `idempotencyKey` and carries a correlation ID.
Obligation and cycle state changes are engine-only: direct writes are refused
by trigger, so a stuck cycle is repaired by issuing the documented transition,
not by updating the row. A cycle that opened against the wrong rule version is
cancelled and reopened; it is never edited in place, because the pinned version
is the evidence that the member's obligation was disclosed before it was owed.
