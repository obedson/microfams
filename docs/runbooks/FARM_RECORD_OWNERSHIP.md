# Farm Record Ownership Boundary

## Scope

Farm-record create, update, delete, and booking-link commands are tenant-scoped and farmer-scoped. A caller may only mutate a record whose `organization_id` is the resolved tenant and whose `farmer_id` is the authenticated user. Update requests accept only operational record fields; ownership and booking linkage are protected command fields.

## Deployment

This is an application-only change. No database migration, data backfill, or feature-flag change is required. Deploy the backend normally, then verify that authenticated farm-record updates, deletes, and booking links succeed for a record and booking owned by the same farmer in the selected organization.

## Monitoring

Track 4xx and database no-row responses from farm-record update, delete, and booking-link endpoints. Investigate a rise after deployment for clients that were incorrectly attempting to change `organization_id`, `farmer_id`, or link another farmer's booking.

## Recovery And Rollback

No existing records are modified by deployment. If rollback is necessary for an application regression, redeploy the preceding backend revision; do not alter tenant or farmer ownership data manually. Restoring the former code removes the owner-level mutation guard and therefore requires an incident record and security approval before use outside an emergency mitigation window.
