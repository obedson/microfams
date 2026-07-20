# Micro Fams V1 Multi-Tenancy Specification

Status: implementation baseline.

## Tenant model

An organization is the security, branding, configuration, reporting, and accounting boundary. V1 organization types are farm businesses, cooperatives, NGOs, government programmes, and agribusinesses. A user may belong to multiple organizations with a different role and permissions in each.

Global user roles do not grant organization access. Every tenant-scoped request must resolve an active organization membership before any domain query or feature-flag decision.

## Organization selection

Clients select an organization with `X-Organization-Id`. This header is an untrusted selector—not proof of access. The backend must look up an active membership for the authenticated user and selected organization before constructing `TenantContext`.

When a user has exactly one active membership, the backend may select it automatically. When a user has multiple memberships, omission is rejected with `TENANT_SELECTION_REQUIRED`; silently choosing the first membership risks cross-tenant writes.

Suspended or closed organizations and suspended or removed memberships cannot produce tenant context.

## Roles and permissions

Built-in roles are owner, admin, finance manager, programme manager, farm manager, auditor, member, and viewer. Roles provide coarse workflow boundaries. Explicit permission strings provide fine-grained capability checks.

Financial approvals, manual ledger corrections, payouts, product configuration, write-offs, distributions, and high-risk feature changes require later maker-checker policies in addition to role membership. No user may satisfy both maker and checker for the same operation.

## Isolation rules

1. Every tenant-owned row carries an organization identifier or, for cross-tenant commerce, explicit source and destination organization identifiers.
2. Repositories receive verified `TenantContext` and include the organization predicate in every read and write.
3. IDs are not authorization. Looking up a record by UUID still requires tenant predicates and domain authorization.
4. Public marketplace discovery uses deliberately projected public views; it never exposes private tenant rows.
5. Cross-tenant bookings, orders, payments, and transfers record both parties and expose only the appropriate projection to each party.
6. Background jobs carry an explicit organization identifier and cannot process an unbounded all-tenant query unless they are audited platform jobs.
7. Cache keys, object-storage paths, exports, logs, metrics, idempotency keys, and provider metadata include tenant context.
8. Platform support access uses time-bound, audited break-glass authorization.

The initial migration creates one isolated personal workspace for each legacy user. It does not place all legacy users into a shared tenant. Domain-specific migrations must backfill ownership based on the existing owner, creator, supplier, or customer relationship before adding non-null constraints.

## Branding and reporting

Branding is stored per organization: display name, logo, colours, support contacts, and optional custom domain. Tenant-supplied URLs and domains require validation before display or routing.

Reports are generated inside one verified organization context unless an authorized platform programme explicitly aggregates participating tenants. Aggregated reports must apply consent, purpose, data-minimization, and disclosure rules and must not expose another tenant's row-level data.

## Invitations and lifecycle

Invitation tokens are stored only as hashes, expire, and may be revoked. Accepting an invitation binds the authenticated email according to the identity policy and creates or activates exactly one membership.

Organization suspension blocks new operations but preserves records and legally required servicing. Closing an organization is a controlled lifecycle operation, not a cascade delete.

## Required tests

Every tenant-owned domain requires positive access tests and negative cross-tenant tests at service, API, and database levels. Tests must cover forged organization headers, missing selections, multiple memberships, suspended memberships, role and permission denial, cross-tenant UUID enumeration, job context, cache separation, export separation, and audit attribution.
