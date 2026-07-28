# Booking Settlements, Disputes, Fees, Refunds, and Supplier Payouts

Status: Proposed for product-owner approval

Proposed version: BS-01 through BS-12

Depends on: approved FC-01 through FC-08 in `FINANCIAL_CORE.md`

## 1. Purpose and scope

This specification defines the Version 1 financial lifecycle after a booking payment succeeds. It covers custody of booking funds, cancellation refunds, service completion, dispute handling, platform fees, supplier settlement, external payout, provider reversal, chargeback recovery, reconciliation, and user-visible evidence.

The rules apply to bookings between a customer organization and a property-provider organization. They reuse the canonical payment, refund, ledger, payout-adapter, feature-flag, audit, and reconciliation engines. They do not authorize savings, lending, investment, general marketplace escrow, or group-treasury economics.

No live money workflow may be enabled merely because this specification is approved. Live activation still requires the provider, credentials, settlement account, webhook configuration, reconciliation certification, compliance owner, approval evidence, and tenant-specific feature flags required by the financial core.

## 2. Definitions

- **Customer**: the farmer who made the booking.
- **Customer organization**: the tenant through which the booking and payment are owned.
- **Supplier**: the property owner or approved beneficiary entitled to booking proceeds.
- **Provider organization**: the tenant that owns the booked property.
- **Booking escrow**: a ledger liability representing captured money that has not yet become releasable to the supplier or platform.
- **Gross booking amount**: the immutable amount successfully paid for the booking.
- **Refunded amount**: the cumulative amount in canonical refunds that are created, submitted, processing, or succeeded.
- **Contested amount**: the portion of unreleased funds frozen by an open dispute.
- **Released amount**: the cumulative amount finally allocated from booking escrow to supplier proceeds and platform fees.
- **Supplier proceeds**: the released amount owed to the provider organization before or after external payout.
- **Settlement**: the accounting allocation of released booking funds.
- **Payout**: the external transfer of supplier proceeds to a verified beneficiary destination.
- **Service completion time**: the audited time at which the canonical booking lifecycle command marks the booking completed.

All amounts use integer minor units and an ISO 4217 currency code. Version 1 initially supports NGN, but records and rules must remain currency-explicit.

## 3. Approved-decision candidates

### BS-01 — Funds custody and conservation

1. A succeeded booking payment MUST be posted to a booking-specific `escrow_funds_held` liability and MUST NOT immediately become supplier revenue, platform revenue, wallet balance, or an available payout.
2. Each booking MUST have an immutable settlement contract linking the booking, customer organization, provider organization, canonical payment, currency, gross amount, rule version, and correlation identifier.
3. At every point, booking-value disposition MUST satisfy:

   `gross paid = unallocated escrow + refund allocation + contested allocation + supplier allocation + platform-fee allocation`

   Pending and completed refunds both remain in the refund allocation; payout and recovery states do not reclassify the original supplier allocation. No category may be negative, and the same amount MUST NOT appear in more than one category.
4. Payment reversals and chargebacks MUST create linked compensating records and journals. They MUST NOT mutate or delete the original payment, settlement, fee, or payout evidence.
5. Cross-organization movements MUST use separate balanced journals in each affected organization, joined by one immutable correlation identifier and explicit due-to/due-from control accounts. A journal MUST NOT contain accounts from two organizations.

### BS-02 — Account and posting model

The implementation MUST provision or map the following purposes through the controlled financial-account service:

- booking escrow funds held;
- supplier settlement payable;
- inter-organization settlement due to;
- inter-organization settlement due from;
- provider clearing;
- platform fee payable;
- supplier booking-service revenue;
- platform booking fee revenue;
- dispute recovery receivable; and
- dispute or chargeback loss expense.

Canonical economic events are:

| Event | Debit | Credit |
| --- | --- | --- |
| Booking payment succeeds | Provider clearing asset | Booking escrow liability |
| Full/partial refund succeeds | Booking escrow liability | Provider clearing asset |
| Supplier allocation in settlement organization | Booking escrow liability | Due-to provider control |
| Matching recognition in provider organization | Due-from settlement control | Supplier booking-service revenue |
| Platform-fee allocation in settlement organization | Booking escrow liability | Due-to platform control |
| Matching recognition in platform organization | Due-from settlement control | Platform booking-fee revenue |
| External supplier payout succeeds in settlement organization | Due-to provider control or pending payout | Provider clearing/bank cash asset |
| Provider organization acknowledges settled cash | Operating cash/provider clearing asset | Due-from settlement control |
| Failed payout restored | Pending payout liability | Supplier settlement payable |
| Confirmed recoverable chargeback | Dispute recovery receivable | Provider clearing/bank cash asset |
| Chargeback classified as loss | Dispute loss expense | Dispute recovery receivable |

The detailed journals MUST be balanced per organization and linked to the booking settlement, domain event, provider event, and reconciliation evidence. Account names and codes are tenant-specific; account purposes and economic meaning are not.

### BS-03 — Settlement eligibility

1. A booking becomes eligible for settlement only when all of the following are true:

   - the booking is `completed` through the canonical lifecycle command;
   - the canonical payment is `succeeded` or `partially_refunded`;
   - the completion time is at or after the tenant-local booking end date;
   - the dispute window has expired;
   - no open dispute, unresolved refund, provider reversal, chargeback, freeze, legal hold, reconciliation exception, or risk hold affects the releasable amount;
   - the supplier organization and beneficiary remain active and authorized; and
   - the applicable acquisition and live-routing flags are enabled.

2. The default dispute window is 48 hours after service completion. It MUST be a versioned, effective-dated tenant rule configurable from 0 to 14 days. Reducing a rule MUST NOT shorten the window already recorded on an existing booking settlement.
3. A booking settlement MUST snapshot the completion time, dispute deadline, timezone, rule version, gross amount, refunded amount, fee rule, supplier allocation, and payout destination fingerprint used for its decision.
4. An idempotent servicing job MAY release eligible settlements automatically. A manual release uses the same atomic command and MUST NOT bypass eligibility.
5. Disabling new settlement creation MUST prevent new exposure but MUST NOT prevent refunds, dispute decisions, reversals, reconciliation, or servicing of already-created obligations.

### BS-04 — Fees

1. The default platform booking fee is zero until an approved tenant fee rule is activated.
2. A fee rule MAY be a fixed minor-unit amount, a basis-point percentage, or both, with explicit minimum and maximum values. The rule MUST identify the payer, beneficiary, currency, tax/withholding metadata, effective dates, and version.
3. Fee calculation MUST use integer arithmetic with round-half-up to the nearest minor unit. The result MUST be deterministic and MUST never exceed the amount being released.
4. A fee is earned only on money released for successfully completed service. Refunded or contested money MUST NOT generate platform fee revenue.
5. Partial settlement calculates the fee on the cumulative supplier-released base, then subtracts fees already allocated. This prevents rounding drift and duplicate fees.
6. Provider processing fees are separate from platform fees. A non-refundable provider fee remains an expense unless provider recovery is explicitly confirmed.
7. The customer and supplier MUST see a pre-payment or pre-confirmation fee breakdown whenever a non-zero fee applies.

### BS-05 — Cancellation and refund policy

1. The existing canonical cancellation policy remains the Version 1 baseline:

   - an unpaid booking may be cancelled without a refund;
   - a paid booking cancelled before the tenant-local start date receives an automatic refund of the remaining refundable amount;
   - a paid booking cancelled on or after its start date enters manual review;
   - a completed booking cannot be cancelled and must use the dispute workflow.

2. Full and partial refunds MUST use canonical `payment_refunds`, enforce cumulative-refund limits, and preserve provider state, reason code, actor, rule snapshot, journal link, and idempotency evidence.
3. A manual refund MUST require `financial.refunds.create` and an independent actor with `financial.refunds.approve`. The maker MUST NOT approve their own request.
4. A refund in `created`, `submitted`, or `processing` state reserves that amount from settlement. Supplier payout MUST NOT consume it.
5. Refund failure returns the amount to the review queue; it does not make the amount automatically releasable.
6. A provider refund fee or unrecovered processing fee MUST be accounted for separately and MUST NOT silently reduce the customer's approved refund.

### BS-06 — Dispute opening and evidence

1. The customer or an authorized customer-organization member may open a dispute after payment and before the dispute deadline. A support actor may open one on behalf of either party only with a recorded reason and tenant scope.
2. Required fields are booking, acting organization, actor, reason code, narrative, requested remedy, contested amount, idempotency key, and correlation identifier.
3. Allowed initial reason codes are:

   - property unavailable or materially misrepresented;
   - supplier no-show or access denied;
   - unsafe or unusable facilities;
   - service materially incomplete;
   - incorrect amount or duplicate charge;
   - agreed cancellation not honoured; and
   - other, requiring a detailed explanation.

4. The contested amount MUST be positive and MUST NOT exceed:

   `gross amount - cumulative refunds - amounts already finally released`.

5. Opening a dispute atomically freezes the contested amount. By default, any undisputed remainder may be released only after the ordinary dispute deadline; a tenant rule may instead freeze the full unreleased balance.
6. Evidence records MUST be append-only, tenant-scoped, timestamped, attributed, malware-scanned where files are used, and protected by retention and access rules. Evidence replacement creates a new version.
7. Sensitive identity, bank, token, and raw-provider information MUST NOT appear in dispute narratives, general logs, exports, or client-visible errors.

### BS-07 — Dispute workflow and resolution

1. Dispute states are `opened`, `evidence_collection`, `under_review`, `resolution_proposed`, `resolved_customer`, `resolved_supplier`, `resolved_split`, `withdrawn`, and `closed`.
2. Transitions are allowlisted, monotonic, idempotent, and audited. Reopening a closed dispute requires a new appeal/review case linked to the original.
3. The customer and supplier MUST each receive notice, see the non-sensitive evidence relevant to them, and receive a deadline to respond. The default response period is 3 calendar days and is a versioned tenant rule.
4. A resolution proposal states the exact customer refund, supplier release, platform fee, recoverable amount, loss amount, reason, evidence references, and accounting preview. Allocations MUST exactly equal the contested amount.
5. A case manager with `booking.disputes.resolve` proposes the resolution. A different actor with `booking.disputes.approve` approves or rejects it. Neither party to the booking may approve the resolution.
6. Approval atomically creates the refund/release/recovery commands and immutable decision evidence. Provider calls are serviced recoverably after the database commitment.
7. Customer resolution sends the approved amount through canonical refunds. Supplier resolution releases it to supplier proceeds. Split resolution does both with exact conservation of value.
8. Withdrawal by the customer does not automatically release funds when a risk, chargeback, legal, or reconciliation hold remains.

### BS-08 — Supplier beneficiary and payout

1. Supplier proceeds belong to the provider organization. A personal property owner may receive them only as that organization's approved beneficiary.
2. Beneficiary destinations MUST be verified through a provider-neutral adapter, encrypted at rest where retained, fingerprinted for comparison, and masked in all ordinary responses.
3. A destination change after booking payment or within 24 hours of payout eligibility creates a risk hold and requires an independent organization approval. The 24-hour period is configurable and snapshotted.
4. Payout creation requires `booking.settlements.release` plus `financial.payouts.create`; servicing an existing payout requires the servicing flags and not the acquisition flags.
5. Payout states and provider behaviour follow FC-05. A timeout remains `processing`; it MUST NOT create a new financial reference or a duplicate transfer.
6. A failed or cancelled payout restores the amount to supplier settlement payable. It MUST NOT restore money to the customer's available balance.
7. Payout success requires exact internal reference, provider reference, amount, currency, beneficiary fingerprint, tenant, and environment validation before posting.
8. Multiple eligible bookings MAY be batched only when every component remains individually traceable and the batch amount equals the sum of its components. Version 1 initially defaults to one payout item per booking settlement.

### BS-09 — Reversals, chargebacks, and post-payout disputes

1. Provider reversals and chargebacks never edit the original payment or payout.
2. If money has not been released, the affected amount is frozen in booking escrow and routed to refund, recovery, or loss handling.
3. If supplier proceeds were allocated but not paid, the supplier payable is reduced through a compensating journal.
4. If payout succeeded, the system creates a recoverable amount against the provider organization and a recovery case. Automatic debit from an unrelated supplier wallet is forbidden unless a separately approved agreement and rule explicitly permits it.
5. Recovery may be satisfied by supplier repayment, an approved offset against future supplier settlements, provider recovery, insurance, or an approved loss write-off. Each method requires explicit evidence and posting templates.
6. A write-off requires maker-checker approval and records recoverable, recovered, and loss amounts separately.
7. Late provider success after an internal failure is treated as an exception and reconciled; it MUST NOT be ignored or paid again.

### BS-10 — Authorization, tenancy, and audit

Separate organization-scoped permissions are required for:

- `booking.disputes.open`;
- `booking.disputes.review`;
- `booking.disputes.resolve`;
- `booking.disputes.approve`;
- `booking.settlements.read`;
- `booking.settlements.release`;
- `booking.payouts.read`;
- `booking.payouts.service`; and
- the existing financial refund, payout, reconciliation, rule, and write-off permissions.

Every read and command MUST validate the acting organization, active membership, resource relationship, role/permission, and feature flag at the service and database boundaries. Customer records, provider records, and platform records are tenant-isolated. Cross-tenant summaries expose only the minimum shared booking and settlement facts.

Sensitive commands record the actor, acting organization, booking, settlement/dispute, before and after state, reason, rule version, correlation identifier, idempotency evidence, and outcome in immutable audit evidence. Denials are audited without leaking protected data.

### BS-11 — Feature flags and degraded operation

Backend-enforced acquisition/servicing pairs are:

- `booking.settlements.create` / `booking.settlements.service_existing`;
- `booking.disputes.open` / `booking.disputes.service_existing`; and
- `financial.payouts.create` / `financial.payouts.service_existing`.

Presentation flags are not authorization. A disabled acquisition flag blocks new exposure. Servicing flags remain independently available for existing refunds, disputes, payouts, callbacks, reversals, reconciliation, and recovery.

Deterministic and sandbox adapters use visibly labelled test money. Live routing additionally requires approved provider metadata, validated credentials, beneficiary-validation configuration, webhook verification, settlement account configuration, reconciliation certification, compliance owner, and activation evidence. Missing live configuration returns a stable configuration error and never simulates success.

### BS-12 — Statements, notifications, and operations

1. Customer views show paid, refundable, refunded, contested, and released amounts plus refund/dispute state.
2. Supplier views show gross amount, refunds, fee calculation, net proceeds, dispute hold, payout state, masked destination, and expected release date.
3. Finance views reconcile each booking from payment through escrow, refund, settlement, payout, fee, reversal, and recovery.
4. Notifications are emitted from durable domain events for payment custody, completion, dispute deadline, dispute opened, evidence requested, resolution proposed/approved, refund state, payout state, reversal, and recovery. Notification failure does not roll back financial state and is retried.
5. Jobs use deterministic clocks, leases, bounded retries, backoff, and dead-letter evidence. They are idempotent and tenant-aware.
6. Existing obligations remain visible and serviceable after a feature is disabled.

## 4. Required data and service boundaries

The implementation is expected to add bounded structures equivalent to:

- `booking_settlement_contracts`;
- `booking_settlement_allocations`;
- `booking_fee_rules` and immutable rule snapshots;
- `booking_disputes`;
- `booking_dispute_evidence`;
- `booking_dispute_resolutions`;
- `booking_supplier_beneficiaries`;
- `booking_supplier_payout_items`; and
- linked recovery cases for reversals and chargebacks.

These records reference the canonical booking, payment, refund, financial account, journal, payout/provider event, reconciliation, organization, and audit structures. Direct mutation by API roles or ordinary backend-role table writes is forbidden; atomic database commands own financial transitions.

Booking domain services decide lifecycle eligibility and dispute rules. Financial domain services own money, journals, provider orchestration, and reconciliation. Controllers, routes, jobs, React components, and adapters MUST NOT construct ledger lines or infer authorization independently.

## 5. Required APIs and user journeys

The implementation MUST provide stable, versioned contracts for:

- reading a booking settlement summary;
- opening a dispute and adding evidence;
- responding to a dispute;
- proposing and independently approving/rejecting a resolution;
- reading customer and supplier dispute timelines;
- servicing eligible settlements;
- validating/selecting a supplier beneficiary;
- reading payout state; and
- servicing provider callbacks, reversals, chargebacks, and reconciliation exceptions.

Every command requires an idempotency key and correlation identifier. Sensitive list/read endpoints require pagination, tenant filtering, masked destinations, and stable error envelopes.

The critical Version 1 journey is:

`pay → hold in booking escrow → supplier confirms → service completes → dispute window → release/fee allocation → supplier payout → reconciliation`

Alternative journeys include full/partial cancellation refund, dispute-to-refund, dispute-to-release, split resolution, payout timeout/failure/reversal, chargeback before release, and chargeback after payout.

## 6. Test and acceptance gates

Implementation is not complete until CI proves:

1. unit/property tests for fee rounding, cumulative allocations, allowed transitions, dispute deadlines, resolution conservation, and idempotency;
2. database integration tests for tenant isolation, concurrent refund/release/dispute attempts, exact reservation, immutable evidence, balanced journals, and atomic rollback;
3. API tests for unauthenticated, wrong-tenant, wrong-role, disabled-flag, changed-replay, masking, limits, and maker-checker cases;
4. payout-adapter contract tests for deterministic, sandbox, live-shaped callbacks, invalid signatures, replay, timeout, duplicate, late success, reversal, and mismatched money/beneficiary;
5. reconciliation tests proving payment, escrow, refund, fee, supplier payable, payout, provider settlement, and bank totals reach zero unexplained variance;
6. frontend component tests for customer and supplier summaries, deadlines, evidence, approval, disabled, degraded, processing, failure, and recovery states;
7. Playwright journeys for successful settlement, pre-start refund, dispute refund, split resolution, payout failure/retry, and disabled live routing;
8. clean-schema and representative legacy-schema migration tests with pre/post control totals;
9. security tests for cross-tenant inference, direct-table mutation, sensitive-data leakage, webhook tampering, and evidence access; and
10. recovery tests showing existing obligations remain serviceable when acquisition flags are disabled.

## 7. Recovery and rollout

Migrations are additive. Existing booking payments, cancellations, refunds, and completed bookings are inventoried before activation. Legacy rows that cannot be tied to a canonical payment and balanced journal enter a read-only quarantine/manual-review queue and are never silently released.

Rollout order is deterministic adapter, sandbox certification, limited tenant pilot, then separately approved live activation. Each stage requires zero unexplained reconciliation variance and a rollback runbook.

Disabling acquisition stops new settlement contracts, disputes, or payouts according to the affected flag. It does not delete evidence or strand callbacks, refunds, open disputes, reversals, reconciliation, or recoveries.

## 8. Approval record

BS-01 through BS-12 are proposed and are not approved by creation of this document. Product-owner approval is required before implementation of booking settlement, dispute, fee, and supplier-payout economics.

Approval, rejection, or requested corrections should be recorded here with the decision date and approved version.
