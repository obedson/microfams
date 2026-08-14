# Investment oversubscription allocation proposal

Status: proposed for product-owner approval

## Purpose

Define deterministic allocation and refund obligations when settled fixed-price subscriptions exceed an approved investment product funding target. This proposal does not execute refunds, post journals, issue units, value assets, distribute returns, or enable redemption.

## Preconditions

An allocation plan may be prepared only when:

- the product version is approved and its offer window has closed;
- the product uses `fixed_unit_price`;
- every included subscription is bound to an immutable posted or reconciled settlement;
- settlement intake for the offer has been finalized;
- the funding target and unit price are positive integer minor units; and
- the tenant actor has `financial.investments.service_existing`.

The allocation capacity is `floor(funding_target_minor / unit_price_minor)` whole units. Any funding-target remainder below one unit is not investable.

## Policies

### Pro rata

1. Convert each settled subscription to requested whole units. A subscription amount that is not exactly divisible by the approved unit price is ineligible and must remain unallocated pending correction or refund.
2. Calculate each eligible subscription's exact entitlement as `requested_units * available_units / total_requested_units`.
3. Allocate the floor of each entitlement.
4. Distribute remaining units by largest fractional remainder.
5. Resolve equal fractional remainders by earlier settlement timestamp, then subscription UUID ascending.
6. An investor's allocation must never exceed their requested units.

### First settled

1. Order eligible subscriptions by settlement timestamp, then subscription UUID ascending.
2. Allocate requested whole units in that order while capacity remains.
3. The final eligible subscription may receive a partial whole-unit allocation.
4. Later subscriptions receive zero units after capacity is exhausted.

## Refund obligations

For every subscription:

`refund_due_minor = settled_amount_minor - allocated_units * unit_price_minor`

Refund due is an investor liability and must never be recognized as investment principal, fee revenue, or distributable return. INV-06 will create immutable planning evidence only. A later approved increment must reserve, post, pay, reverse, and reconcile refund obligations before oversubscribed allocation can be executed.

## Governance and invariants

- Planning and independent approval require different actors.
- Plans pin the product version, policy, settlement cutoff, included settlement identities, ordered tie-break evidence, unit capacity, allocations, refund obligations, correlation ID, and request hash.
- The same tenant idempotency key and facts return the same plan; changed facts are rejected.
- Plan approval is allowed only if allocated units equal capacity when demand is at least capacity, every allocation is non-negative, and settled amount equals allocated principal plus refund due.
- Cross-tenant records are rejected and all evidence is immutable.
- Disabling `financial.investments.service_existing` prevents new plans and approvals without hiding existing evidence.
- No plan may modify settlement journals or INV-05 unit records.

## Recovery

Before any plan is approved, rollback means disabling investment servicing and removing empty planning tables. After durable evidence exists, preserve it and use a forward corrective migration. Execution must remain disabled until refund ledger mappings, provider recovery, reconciliation, and operational runbooks are approved and tested.

## Approval decisions

| Decision | Recommendation | Status |
| --- | --- | --- |
| INV-06A | Whole-unit capacity uses floor division of funding target by unit price | Proposed |
| INV-06B | Pro-rata uses largest-remainder allocation with deterministic settlement-time and UUID tie-breaks | Proposed |
| INV-06C | First-settled permits a partial whole-unit allocation for the final eligible subscription | Proposed |
| INV-06D | Unallocated settled cash becomes an explicit refund liability | Proposed |
| INV-06E | Maker-checker approval is required before any allocation execution | Proposed |

Approved by: _pending_

Approval date: _pending_

