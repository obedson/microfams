# ADR-0003: Journal as the financial source of truth

- Status: Accepted
- Date: 2026-08-28

## Context

Wallet balances, settlements, savings, loans, investments, escrow, dividends, and cooperative accounting must remain reconcilable across retries, provider callbacks, and corrections.

## Decision

The immutable double-entry journal is the financial source of truth. Money uses integer minor units or an explicitly documented fixed-precision type. Every posting balances debits and credits, uses idempotency constraints, and records tenant and source references.

Balance columns and snapshots are derived caches. Posted entries are never edited or deleted; corrections use reversals or compensating entries. External money movement retains pending, failed, reversed, and reconciled states.

## Consequences

Financial reads must state whether they use the journal or a derived cache. Rebuild and reconciliation procedures can recover caches from journal evidence. Schema and service tests must prove balanced postings, idempotency, immutability, tenant isolation, and correction behavior.
