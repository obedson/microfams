# Booking settlement statements

## Scope

The settlement endpoint returns one organization-scoped statement for an existing booking obligation. It remains available through `booking.settlements.service_existing` when settlement acquisition is disabled.

## Perspectives

The database derives the perspective from the authenticated acting organization; callers cannot select it.

- Customer statements expose paid, refundable, pending-refund, refunded, contested, and released amounts together with refund and dispute state.
- Supplier statements expose gross value, refunds, the fee calculation and frozen rule evidence, net proceeds, dispute holds, payout state, masked destination, and expected release time.
- Finance statements are included only for actors with `financial.reconciliation.manual` or `financial.reconciliation.approve`. They link payment, escrow, refunds, disputes, supplier payable, platform fee, payouts, reversals, and recovery cases.

No statement exposes an unmasked payout destination, provider credential, customer evidence body, or another tenant's private operational data.

## Control total

All amounts use integer minor units. The booking-level control is:

`gross = unallocated escrow + pending refunds + final refunds + contested + supplier payable + platform fee + reversals`

`unexplained_variance_minor` is the difference between the two sides. A non-zero result is an incident: disable new settlement exposure for the affected tenant, keep servicing enabled, inspect the immutable payment/allocation/journal/provider evidence, and resolve through an approved compensating workflow.

## API and recovery

`GET /api/bookings/:id/settlement` calls `read_booking_settlement_statement`. The function validates the booking relationship, active tenant permission, and finance permission at the database boundary.

If deployment of this read model must be rolled back, restore the prior application version without deleting settlement evidence. The migration is additive; the legacy `read_booking_settlement_summary` function remains available during rollback.
