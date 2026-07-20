# Organization Verification Specification

Status: implementation baseline.

## Purpose

Organization verification establishes that a Micro Fams tenant represents a registered or authorized entity. It does not grant regulatory approval, financial-product activation, or government endorsement.

## Scope

V1 supports Nigerian and future jurisdiction-specific evidence through provider-neutral adapters. Registration evidence types are CAC registered company, CAC business name, NGO registration, government programme authorization, and an explicitly reviewed alternative.

Only an active organization owner or administrator may submit verification. A submission includes a versioned attestation that the actor is authorized to represent the organization and permit verification.

## Data minimization

Raw registration numbers are sent to the configured provider only in process memory. Persistence uses a jurisdiction- and evidence-scoped HMAC fingerprint. Provider payloads are not stored or logged. Stored evidence is limited to masked identifiers, provider references, a hash of normalized provider evidence, decisions, reason codes, actor attribution, and timestamps.

A registration fingerprint may verify only one active organization. Revocation preserves historical evidence.

## States

Requests move from `created` to exactly one provider outcome: `verified`, `review_required`, `rejected`, or `failed`. Requests may be cancelled before a terminal provider outcome. Provider errors never create a verified state.

`review_required` is not verified. Manual evidence, platform review, suspension, revocation, and appeal are handled by the subsequent trust-review workflow.

## Feature and provider rules

`integration.organization_verification` controls new submissions at the backend. Reading existing status remains available when submission is disabled. Production requires a configured live or approved sandbox adapter; deterministic results are prohibited in production.

Provider results do not automatically enable payments, credit, investments, government dashboards, or other regulated capabilities. Those remain subject to their own backend flags and compliance controls.

## Authorization and isolation

Requests, attestations, verified evidence, and events belong to one organization. Database functions verify active owner/admin membership for submission and active membership for sanitized status reads. Browser and mobile Supabase roles receive no direct table or function mutation privileges. Tests must prove an unrelated tenant cannot infer verification evidence.
