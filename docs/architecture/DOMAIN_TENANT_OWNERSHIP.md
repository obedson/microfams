# Domain tenant ownership

## Ownership model

Micro Fams uses explicit organization ownership rather than inferring a tenant from the current user. A user may belong to several organizations, so the verified `X-Organization-Id` request context determines which workspace is active.

| Domain record | Ownership |
| --- | --- |
| Property, farm record, group, wallet, contribution | One `organization_id` |
| Booking | Customer `organization_id` and `provider_organization_id` |
| Marketplace order | Buyer `organization_id` and `supplier_organization_id` |
| Course, marketplace product, audit event | Nullable `organization_id` permits explicitly global/platform content |
| Receipt, refund | Inherits the customer organization from its booking |
| Wallet transaction | Inherits the organization from its user wallet or group ledger |

Cross-organization bookings and orders are shared transaction records, not duplicated rows. Each participating organization may read the shared record; unrelated organizations may not.

## Legacy backfill

The organization foundation creates one isolated personal workspace per existing user, using the user's UUID as the organization UUID. The ownership migration uses that deterministic mapping to backfill existing data:

- property and farm data follows its owner/farmer;
- a booking's customer follows its farmer and its provider follows the booked property;
- a group follows its creator;
- a product follows its supplier when it is not platform-global;
- an order follows its buyer and the product supplier;
- financial child records inherit ownership from their parent booking, wallet, group, or contribution cycle.

Required operational ownership columns become non-null only after backfill. Global catalog and education rows remain nullable by design.

## Enforcement layers

1. Tenant resolution verifies active membership and never trusts the organization header alone.
2. API repositories add organization predicates even though the backend uses a Supabase service key that can bypass row-level security.
3. Database triggers derive and validate ownership on writes, including both sides of bookings and orders.
4. Row-level security provides defense in depth for any future authenticated direct database access.

Property mutations and booking workflows are the first API paths migrated to verified tenant context in this change. Remaining farm, group, marketplace, education, reporting, and background-job queries must adopt the same explicit predicate before those modules are considered tenant-safe for release.

## Isolation contract

The clean-schema test creates provider, customer, and unrelated organizations. It proves that:

- the provider sees its property and the shared booking;
- the customer sees the shared booking but not the provider's private property record;
- the unrelated organization sees neither record;
- group and wallet ledger ownership is derived automatically.
