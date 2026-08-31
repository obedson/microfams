# Organization Settings Operations

## Scope

This runbook covers tenant-scoped notification preferences and reporting/export
policy settings exposed by GET /api/organizations/current/settings and
PATCH /api/organizations/current/settings.

## Authorization and safety

- Only active organization owners and administrators may read or change these
  settings through the API.
- The backend derives the organization and actor identifiers from authenticated
  tenant context. Request bodies cannot select another tenant.
- Database writes are accepted only through update_organization_settings.
  Direct service-role table mutations are denied.
- Every successful update records organization.settings.updated in
  organization_audit_log, including before and after values.
- Reporting/export settings do not themselves authorize cross-tenant reporting.
  Any such workflow must separately enforce explicit consent, purpose
  limitation, data minimization, disclosure controls, and audit evidence.

## Rollout verification

1. Apply the schema manifest in order and confirm organization_settings has
   row-level security enabled.
2. Confirm service_role can select the table and execute the update function,
   but cannot insert, update, or delete table rows directly.
3. Update one non-production tenant through the API.
4. Verify the stored tenant identifier and the matching
   organization.settings.updated audit entry.
5. Confirm an administrator can update operational settings and that a
   non-administrator receives an authorization failure.

## Recovery and rollback

- To stop new changes, disable or remove the settings routes at the application
  layer and revoke service-role execution on update_organization_settings.
- Existing rows remain readable and must not be hidden or deleted.
- Restore execution only after the application and migration versions are
  compatible and clean-schema verification passes.
- Correct an erroneous setting through a new authorized API update so the
  correction is audited. Do not edit rows manually.

## Evidence

- API contract: backend/src/tests/organizationSettingsApi.test.ts
- Database contract: backend/tests/schema/test-organization-settings.sql
- Clean-schema gate: backend/scripts/verify-clean-schema.sh
