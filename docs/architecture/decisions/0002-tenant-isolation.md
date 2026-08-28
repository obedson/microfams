# ADR-0002: Tenant isolation and authorization context

- Status: Accepted
- Date: 2026-08-28

## Context

Micro Fams stores organization, cooperative, programme, financial, and operational data for unrelated tenants. A client-supplied organization identifier is not proof of membership or authority.

## Decision

Every tenant-owned record carries an organization or tenant identifier. Authenticated server middleware resolves actor and tenant context; domain services authorize the actor, resource, and command; database constraints, functions, and row-level security provide a second boundary.

Global platform administration uses explicit, audited assignments and never inherits from a legacy user role. Cross-tenant reads, exports, analytics, jobs, and aggregate reports require an explicit platform capability and tests proving the minimum disclosed data.

## Consequences

APIs cannot trust tenant identifiers from headers or bodies without resolving them against authenticated membership. Repository methods require tenant context for tenant-owned operations. Tests must cover wrong-tenant reads, mutations, aggregates, exports, and inference paths.
