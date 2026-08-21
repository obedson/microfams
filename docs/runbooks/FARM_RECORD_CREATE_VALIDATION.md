# Farm Record Create Validation

## Scope

Farm-record creation now validates that any linked booking belongs to the resolved tenant and authenticated farmer, and that any supplied property matches the booking property. Standalone farm records without a booking remain allowed.

## Deployment

No migration is required. Deploy the backend, then verify one booked create path and one standalone create path in the target tenant.

## Recovery And Rollback

Rollback is code-only. Redeploy the prior backend revision if this creates an unexpected client regression. Do not loosen tenant or farmer ownership data in the database.
