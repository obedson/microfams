# Tenant Isolation Operations

Micro Fams derives tenant context from the authenticated user's active organization membership. Clients may request an organization through `X-Organization-Id`, but services must verify membership and permissions before accessing tenant-owned records. Database queries, RPCs, exports, analytics, and background jobs must retain the verified organization identifier.

## Verification

Before release, run tenant-isolation tests with the two stable synthetic tenants in `backend/tests/fixtures/tenantFixtures.ts`. Verify that tenant A cannot read, mutate, aggregate, export, download, enqueue, or infer tenant B's data. Include database/RLS, API authorization, reporting, analytics, outbox, and scheduled-job coverage for every changed domain.

A missing organization selector, malformed UUID, inactive membership, or insufficient permission must fail before repository access. Do not accept organization IDs from request bodies when verified tenant context is available.

Database membership checks must require both an active membership and an active organization. Suspended and closed organizations must return no tenant-owned rows even when a membership record remains active.

Treat a present but empty or whitespace-only `X-Organization-Id` header as malformed. It must not fall back to automatic selection. Omission is allowed only when the authenticated user has exactly one active membership in an active organization. Multiple active memberships require an explicit selector, while forged selectors and suspended memberships or organizations use the same neutral `TENANT_ACCESS_DENIED` response.

The tenant selection contract is exercised at three layers:

- `tenantSelectionApi.test.ts` verifies the HTTP status and stable error codes.
- `tenantService.test.ts` verifies membership-selection rules.
- `tenantRepository.test.ts` verifies the active-membership and active-organization query predicates.

Null ownership is never a fallback tenant. Legacy null-owned rows must remain invisible unless the domain specification deliberately defines a global record, such as approved global education or marketplace catalogue content with its own policy and projection.

## Deployment and rollback

Apply tenant policy hardening after all domain migrations so later installers cannot restore permissive policies. Run the clean-schema suite and the hosted legacy-upgrade job before deployment. An application rollback does not require weakening the database boundary. If a legitimate global workflow is blocked, add a domain-specific projection and regression test; do not restore generic null-owner visibility or bypass active-organization checks.

## Incident containment

Treat any suspected cross-tenant response, aggregate, export, job, notification, signed URL, or audit record as a security incident.

1. Record UTC timestamps, request/correlation IDs, authenticated user, verified organization, endpoint or worker, and affected resource types.
2. Disable the affected backend feature flag or worker to stop new operations without hiding existing records.
3. Preserve API, audit, queue, and database evidence. Do not delete, rewrite, or manually reassign tenant-owned rows.
4. Revoke active signed URLs or provider access where supported, and prevent new exports or notifications for the affected workflow.
5. Notify platform security and the domain owner before restoring service.

## Investigation

Confirm whether the tenant boundary failed in middleware, service input, repository predicates, RPC parameters, RLS policies, export filters, cache keys, object-storage paths, analytics queries, or job payloads. Test with two unrelated tenants and verify both direct identifiers and aggregate side channels.

Use read-only database queries scoped by organization ID. Never disable RLS in production or repair an incident by updating organization identifiers manually.

## Recovery

Correct the boundary at every affected layer and add a regression test that proves tenant A cannot observe tenant B. If data was changed, use the domain's approved reversal or compensating workflow. Rebuild derived caches, reports, or exports only after source records are verified.

Re-enable the feature or worker only after the complete tenant-isolation suite and required CI checks pass on the exact release commit. Retain the incident record, affected tenant list, remediation commit, test evidence, and approval.
