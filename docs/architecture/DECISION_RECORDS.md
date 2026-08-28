# Architecture decision records

Architecture decision records (ADRs) capture repository-wide choices that constrain implementation. Accepted ADRs apply to new work and material changes; superseding one requires a new ADR that links the previous record.

## Accepted decisions

- [ADR-0001: Modular monolith and domain boundaries](decisions/0001-modular-monolith.md)
- [ADR-0002: Tenant isolation and authorization context](decisions/0002-tenant-isolation.md)
- [ADR-0003: Journal as the financial source of truth](decisions/0003-financial-journal.md)
- [ADR-0004: Provider adapters and backend feature flags](decisions/0004-provider-adapters-feature-flags.md)

## Record format

Every new ADR must include status, date, context, decision, consequences, and any superseded record. Use Proposed, Accepted, Deprecated, or Superseded as status values. ADRs describe durable architecture choices; business rules remain in approved specifications.
