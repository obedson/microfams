# Group Treasury Disbursements Runbook

## Scope

GT-06A governs money leaving a group's treasury to an internal beneficiary — a
member, another group, or a project. External provider payouts, provider timeout
recovery, and emergency expenditure are GT-06B; the reservation primitive
installed here is what that slice will consume.

The rule that shapes everything else: **voting alone never moves money, and
money never moves against a mutable balance.** Available funds are derived from
posted journal lines minus active reservations, so the legacy
`groups.group_fund_balance` column is never read or written by this domain.

## Lifecycle

```
requested ─▶ approved ─▶ executed ─▶ reversed
    │            │
    ├─▶ rejected ├─▶ cancelled
    └─▶ expired  └─▶ expired
```

`requested` records the ask. `approved` is the moment funds become committed: it
verifies the governance outcome, verifies separation of duties, snapshots what
was true, and takes the reservation — all in one transaction, so a failed check
leaves no reservation behind. `executed` posts the balanced internal journal and
consumes the reservation. Reversal posts an opposing journal; the original entry
is never deleted.

## Separation of duties

Clause 3 requires three things the vote alone cannot provide:

| Requirement | Where enforced |
| --- | --- |
| Final checker holds `groups.treasury.approve` | `group_treasury_checker_permitted` |
| At least two distinct approving actors | counted from current votes at approval |
| Proposer ≠ checker ≠ beneficiary | table CHECKs and the approve function |

The seeded office set granted the treasurer `groups.treasury.make` but gave no
office an approve permission, so before this slice **no disbursement could pass
its own final check**. The chair now holds `groups.treasury.approve`: the
treasurer prepares, the chair countersigns. A trigger on
`group_office_definitions` adds the permission to any chair office as it is
written, so both constitution seed paths stay covered without duplicating them.

## Budgets

A budget is the authorised envelope a request must name. `committed_minor` and
`disbursed_minor` are maintained by the engine from reservation and disbursement
transitions — never written by a caller. The ceiling is checked at request time
so an unfundable ask is refused before it reaches a voting round.

A constitution may disclose a low-value band with lower thresholds. The band is
recorded as a whole or not at all: a ceiling with no thresholds would silently
fall back to the default and read as a weaker rule than it is. The basis applied
(`default` or `low_value_band`) is stored on the disbursement either way.

## Execution revalidates

Approval snapshots; execution rechecks. Between the two, the group may have been
suspended, the constitution may have changed, the window may have closed, or the
budget may have been shut. Execution refuses on any of these rather than trusting
the approval — clause 5 is explicit that both steps validate independently.

## Reservations are exactly once

A reservation is consumed or released once, never both and never twice. The
unique constraint on `consumed_journal_entry_id` makes a double consume
impossible; `release_group_treasury_reservation` returns `false` rather than
raising when the reservation is already settled, so a retried failure callback
cannot free the same funds twice. Releasing an executed disbursement is refused
outright.

## Safety and recovery

All four tables are engine-locked: direct writes are refused by trigger, so a
stuck disbursement is repaired by issuing the documented transition, not by
updating the row. A wrongly executed payment is corrected by reversal, which
leaves both the payment and its correction in the register. A disbursement
approved against the wrong budget is released and re-requested; it is never
edited in place, because the approval snapshot is the evidence that the spend was
authorised on the terms disclosed at the time.

Feature flags follow the acquisition/servicing split:
`groups.treasury.create_disbursement` gates activating budgets and raising
requests; `groups.treasury.service_existing` gates approve, execute, release, and
reverse. Servicing must stay available when acquisition is switched off, or funds
reserved before the switch could never be paid out or returned.
