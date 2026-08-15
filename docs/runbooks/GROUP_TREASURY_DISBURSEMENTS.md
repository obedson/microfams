# Group Treasury Disbursements Runbook

## Scope

GT-06A governs money leaving a group's treasury to an internal beneficiary — a
member, another group, or a project. GT-06B adds the **external channel**: money
leaving to a verified off-platform account through the shared provider payout
stack, plus the provider timeout and reconciliation recovery that follows from a
payout the platform cannot itself settle. Emergency expenditure and its mandatory
ratification are a fast-follow slice; the external channel documented below is
what it will build on. The external channel inherits the shared payout adapter's
NGN-only ceiling — internal budgets stay multi-currency, an external spend does
not.

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

## GT-06B: the external channel

An external disbursement pays a **verified, separately approved off-platform
beneficiary** through the shared provider payout stack. It reuses everything
above — budget, governance, separation of duties, the reservation primitive — and
adds two things: a group-scoped beneficiary registry, and a payout lifecycle that
sits between `approved` and the terminal state.

```
requested ─▶ approved ─▶ disbursing ─▶ executed
    │            │            │
    ├─▶ rejected ├─▶ cancelled └─▶ failed
    └─▶ expired  └─▶ expired
```

`disbursing` is new: it is the window in which a provider payout exists but has
not confirmed. `begin` moves `approved ─▶ disbursing`; a confirmed provider
success moves `disbursing ─▶ executed`; a provider failure moves
`disbursing ─▶ failed`. `disbursing` and `failed` carry no execution journal and
no `executed_at` — the GT-06A state/journal CHECKs already guarantee this.

### The beneficiary registry is maker–checker

`group_treasury_beneficiaries` mirrors the booking payout registry: the service
layer owns AES-256-GCM encryption and the database sees only ciphertext, a
sha256 destination fingerprint, and masks — never a raw account number. A
destination is registered `pending_approval` by one officer and moved to
`verified` by a **different** one (`GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK`
if the same actor tries both), who must hold the treasury approve permission and
not be the beneficiary. Only a `verified` destination can be named on a request
(`GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED`); the partial unique index keeps one
verified destination per `(group, provider, environment, fingerprint)`.

### Posting is deferred (Option B)

Money is **committed at `begin` but not posted.** `begin` creates and reserves
the provider payout (`GTP-<disbursement>` internal reference, `reserved` state)
and leaves the GT-06A reservation active — the commitment stands, but no journal
line exists yet, because the money has not confirmably left. Posting happens on
confirmed success **and only there**: `succeed_group_treasury_payout` posts the
balanced journal — DEBIT `GROUP.<key>.TREASURY`, CREDIT
`GROUP.<key>.EXTERNAL_PAYOUT_CLEARING` — consumes the reservation exactly once,
turns the budget commitment into spend, and moves the disbursement to `executed`.
Available funds are unchanged by success: debiting the treasury and consuming the
reservation net to the figure the reservation already reflected.

A failure (`fail_group_treasury_payout`) posts nothing, releases the reservation
with `PROVIDER_PAYOUT_FAILED`, and returns the commitment to the available pool.
Both functions are idempotent — a retried provider callback returns the payout
unchanged and never frees or spends the same funds twice.

### Reconciliation: a success after a failure is recorded, never repaid

The one case the provider stack cannot make atomic is a payout the platform
marked `failed` (funds already released) that the provider later confirms **did**
settle. Repaying would debit the treasury twice. Instead
`record_group_treasury_late_payout_success` writes a
`group_treasury_late_payout_exceptions` row stamped
`recorded_without_repaying: true`, posts no journal, and leaves the budget and the
`failed` disbursement exactly where the failure left them. The row is the evidence
that a manual settlement is owed off-ledger; it is idempotent on
`(payout_id, provider_reference)`. The exception table is engine-locked like the
registry, so it is written only through this function.

### Operating the external channel

`begin`, `sync`, verify, and reject are **servicing** commands
(`groups.treasury.service_existing`); registering a destination and raising an
external request are **acquisition** (`groups.treasury.create_disbursement`).
Internal `execute` refuses an external disbursement outright
(`GROUP_TREASURY_CHANNEL_NOT_INTERNAL`) — the two channels never cross. A stuck
`disbursing` payout is resolved by driving the provider outcome (success or
failure) through the documented functions, never by editing the row: both new
tables are engine-locked exactly as the GT-06A four are.

## GT-06B2: emergency expenditure

Emergency spending is disabled until an organization configures a constitution-pinned cap, member-notice deadline, and ratification window. A request must carry a reason and evidence and cannot benefit its maker. Two distinct treasury approvers are required; only the second approval posts one balanced journal.

That transaction also creates a linked ratification proposal and durable in-app notices for every active member. Approval records `ratified`; rejection or expiry records `ratification_rejected` without deleting or rewriting the original journal.

## GT-07A: treasury statements

The group treasury statement is reconstructed from posted journal lines at a caller-supplied cutoff. Reservations are reconstructed from their creation and settlement timestamps at the same cutoff, so available value is reproducible rather than based on current mutable state.

Every active paid member may read the group's aggregate treasury statement and contribution ownership classification. The response contains no other member's contribution rows or identifiers; member-attributed detail remains private.
