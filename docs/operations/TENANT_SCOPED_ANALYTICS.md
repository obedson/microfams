# Tenant-scoped analytics operations

The analytics API resolves an active organization before executing any route. Property-side metrics use `properties.organization_id` and `bookings.provider_organization_id`; farmer dashboard totals use `bookings.organization_id`. Analytics cache keys include the resolved organization ID.

## Deployment

Apply `install_tenant_scoped_booking_analytics.sql` through the schema manifest before deploying the backend. Confirm `booking_analytics.organization_id` exists and that `/api/analytics/*` requests include a valid `X-Organization-Id` when the user has more than one active membership.

## Verification

Run backend typecheck, focused tenant/API tests, and `npm run test:schema`. A property ID belonging to another organization must return the neutral property-not-found response and must not invoke analytics aggregation.

## Rollback

Disable traffic to `/api/analytics` before rolling back the backend because the previous implementation was not tenant-safe. Revert the application commit and restore the prior `booking_analytics` view definition from `001_farmle_platform_enhancement_schema.sql`. Do not re-enable analytics until an equivalent tenant boundary is in place; cached tenant-prefixed entries may expire naturally or be removed with the existing analytics cache invalidation tooling.