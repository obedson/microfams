# ADR-0001: Modular monolith and domain boundaries

- Status: Accepted
- Date: 2026-08-28

## Context

Version 1 spans platform, finance, governance, farm operations, commerce, education, intelligence, and institutional reporting. These domains share tenancy, authorization, transactions, and operational infrastructure, while premature distributed services would add failure modes and reconciliation overhead.

## Decision

Build Version 1 as a modular monolith. Domain rules live in domain services and are exposed through typed application interfaces and domain events. Controllers, routes, React components, jobs, and provider adapters orchestrate or translate; they do not own business rules.

Cross-domain database changes must preserve explicit ownership and transactional boundaries. A microservice, infrastructure CQRS, or independently deployed domain requires a superseding ADR.

## Consequences

The application can use one deployment and transactional database while keeping module boundaries reviewable and testable. Shared code is limited to genuine platform concerns. Scaling one domain independently may require later extraction, but extraction starts from an explicit interface rather than route-level coupling.
