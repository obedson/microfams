# Organization Membership Access Operations

## Scope

This runbook covers tenant-scoped membership listing and owner-governed role and
permission changes exposed by:

- GET /api/organizations/current/memberships
- PATCH /api/organizations/current/memberships/:membershipId/access

## Authorization and safety

- Active owners and administrators may list current memberships.
- Only an active owner may change a non-owner membership's role or permissions.
- The backend derives the organization and actor from authenticated tenant
  context. Request bodies cannot select another tenant.
- Ownership cannot be assigned, removed, or transferred through this command.
  Ownership changes remain disabled until a separate legal-identity workflow is
  approved.
- Direct service-role membership updates remain revoked. Changes execute only
  through update_organization_membership_access.
- Every successful change records organization.membership.access_updated with
  before and after role and permission values.

## Rollout verification

1. Apply the schema manifest and confirm browser roles cannot execute the access
   command or mutate organization_memberships directly.
2. Confirm an owner can update one active non-owner membership.
3. Verify permissions are normalized, the membership remains in the same
   organization, and the matching audit record contains before/after evidence.
4. Confirm administrators, outsiders, suspended memberships, and cross-tenant
   membership identifiers cannot change access.
5. Confirm owner memberships cannot be changed through the generic access API.

## Recovery and rollback

- To stop new changes, remove or disable the PATCH route and revoke service-role
  execution on update_organization_membership_access.
- Existing memberships and audit evidence remain readable and must not be
  deleted or hidden.
- Correct an erroneous role or permission set through a new authorized command
  so the correction is independently auditable. Do not update rows manually.

## Evidence

- API contract: backend/src/tests/organizationMembershipApi.test.ts
- Database contract: backend/tests/schema/test-organization-membership-access.sql
- Clean-schema gate: backend/scripts/verify-clean-schema.sh
