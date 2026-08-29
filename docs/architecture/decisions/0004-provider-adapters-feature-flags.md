# ADR-0004: Provider adapters and backend feature flags

- Status: Accepted
- Date: 2026-08-28

## Context

Payments, payouts, identity, messaging, storage, weather, satellite, and AI depend on external providers with different credentials, availability, certification, and regulatory constraints.

## Decision

Provider integrations implement typed interfaces with deterministic test, sandbox, and live adapters. Provider-dependent, regulated, institutional, and staged capabilities are enforced by tenant-aware and environment-aware backend feature flags.

Live routing requires credentials, configuration, approval metadata, webhook controls, and reconciliation evidence in addition to an enabled flag. Missing configuration fails closed and never falls back to simulated success. Servicing flags remain separate from new-exposure flags so disabling acquisition does not hide or corrupt existing obligations.

## Consequences

Domain services depend on provider contracts rather than SDKs. Provider callbacks verify raw signatures and idempotency before mutation. Operational runbooks must document disable, recovery, reconciliation, and re-enable procedures.
