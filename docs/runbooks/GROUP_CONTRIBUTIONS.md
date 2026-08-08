# Group Contributions Runbook

## Scope

GT-04 classifies every contribution product before collection and fixes economic
ownership from that classification. A contribution rule is a governance decision:
it executes only from an approved, closed `contribution_rule` proposal. Payment
confirmation and allocation are one transaction, so a confirmed contribution is
always explained by a journal entry and by the rule version in force when it was
paid.

Contribution cycles, obligations, penalties assessment, and dashboards are GT-05
and are deliberately outside this increment. The penalty and discount *rule*
tables land here so a cycle cannot later be opened against undisclosed terms.

## Classification fixes ownership

| Product class | Ownership | Credit account |
| --- | --- | --- |
| `membership_fee` | `group_income` | group revenue |
| `periodic_due` | `group_income` | group revenue |
| `member_capital` | `member_attributed` | member equity liability |
| `savings` | `member_attributed` | member equity liability |
| `project_subscription` | `project_restricted` | restricted project liability |

Ownership is derived by CHECK constraint, not chosen by the caller, so member
capital and savings can never be reclassified as group income by an update. There
is no interchangeable "group fund balance": each class posts to its own account.
A `member_attributed` rule is refused unless it discloses both a withdrawal rule
and a loss-allocation rule; a `project_subscription` must name its project and no
other class may claim one.

## Proposal contract

A `contribution_rule` proposal to adopt a new product uses:

```json
{
  "action": "adopt",
  "productKey": "monthly_due",
  "displayName": "Monthly due",
  "productClass": "periodic_due",
  "purpose": "Cover monthly governance and operating costs",
  "amountMinor": 250000,
  "currency": "NGN",
  "permittedRails": ["paystack", "bank_transfer"],
  "refundRuleCode": "NO_REFUND",
  "revenueAccountCode": "DUES_INCOME"
}
```

An amendment uses `"action": "supersede"` with `productId` instead of
`productKey`/`displayName`. A `member_capital` or `savings` payload must also
carry `withdrawalRuleCode` and `lossAllocationRuleCode`; a `project_subscription`
must carry `projectId`.

Amendments supersede, never rewrite. The product class of a live product is
immutable, because reclassifying it would change who owns money already
collected. Version 1 may not claim a predecessor.

## Executing a rule

1. Close voting and confirm the proposal is `approved`.
2. `POST /:id/proposals/:proposalId/contribution-execution` with the current
   proposal state version and a unique `Idempotency-Key`.
3. Execution fails closed if the constitution changed since the proposal was
   raised, the group is not active, the proposal type is wrong, the product key
   already exists, or the product has no effective rule to supersede.
4. Read `/:id/contribution-products` to confirm the effective rule and its
   disclosed terms.

## Collecting and allocating

1. `POST /:id/contribution-products/:productId/payments` starts a payment. The
   amount defaults to the effective rule's amount; an explicit `amountMinor` is
   honoured because GT-04 clause 5 permits partial and excess payments. Currency
   and payer are read server-side and never taken from the request body.
2. The payment engine verifies the provider result. A client-reported success is
   never trusted.
3. `POST /:id/contribution-products/:productId/allocations` posts the allocation.
   It refuses any payment that is not `succeeded`, not `contribution`-sourced,
   not for this product, not paid by this member, or whose currency differs from
   the rule.
4. Both commands are idempotent by correlation ID, and an allocation is unique
   per payment, so a retry after a network failure cannot double-post.

Taking new contribution money is gated by `groups.contributions.accept_new`.
Allocation is gated by `groups.contributions.service_existing` instead, so
already-captured payments can still be posted when acquisition is switched off.

## Safety and recovery

All tables are tenant-read-only and write-locked behind the contribution engine
trigger; there is no direct insert or update path. Reverse an allocation with
`reverse_group_contribution_allocation` against a verified `payment_reversals`
row — it posts the mirror journal and marks the allocation `reversed` rather than
deleting evidence. Correct a wrong approved rule through a later supersede
proposal; never edit or delete a rule version, allocation, or event.

A supersede is safe against history because every allocation captures the rule
version that explained it, so an amendment cannot restate money already
collected. GT-04 clause 4 additionally forbids retroactive change to an existing
cycle; cycles arrive in GT-05, which must add the open-cycle guard to the rule
executor at that point.
