# Micro Fams V1 Feature-Flag Specification

Status: implementation baseline. Financial product rules remain subject to the separate financial approval specification.

## Purpose

Feature flags control rollout and provider availability; they do not replace authorization, licensing, tenant isolation, validation, or accounting controls. Decisions are made by the backend for every protected command. Hiding a frontend button is presentation only.

## Evaluation model

Every decision receives an environment and may receive an authenticated actor, tenant, and jurisdiction. Active overrides are layered in this order:

1. catalog default;
2. global override;
3. jurisdiction override;
4. tenant override;
5. actor override.

More-specific configuration is merged over less-specific configuration. Overrides are effective-dated and environment-specific. The global emergency stop supersedes every override.

Tenant and actor context must come from authenticated server context, never from an unverified request header or client-supplied body field.

## Safe failure behaviour

Flags that create new financial exposure or call an optional provider fail closed when flag storage is unavailable. Flags required to service existing customer obligations fail open so that callbacks, reconciliation, refunds, withdrawals, statements, maturity, collections, and corrections continue.

The emergency stop is stronger than failure-mode handling and is reserved for an active security, legal, provider, or integrity incident. Activating it requires an explicit reason, authorized operator, audit entry, and incident record.

## Financial controls

Each financial domain separates acquisition from servicing:

| Domain | New exposure | Existing obligations |
| --- | --- | --- |
| Payments | `financial.payments.accept_new` | `financial.payments.service_existing` |
| Payouts | `financial.payouts.create` | `financial.payouts.service_existing` |
| Wallets | `financial.wallets.transact` | `financial.wallets.read` |
| Escrow | `financial.escrow.create` | `financial.escrow.service_existing` |
| Savings | `financial.savings.enrol` | `financial.savings.service_existing` |
| Investments | `financial.investments.subscribe` | `financial.investments.service_existing` |
| Loans | `financial.loans.originate` | `financial.loans.service_existing` |
| Dividends | `financial.dividends.declare` | `financial.dividends.service_existing` |
| Accounting | `financial.accounting.post` | `financial.accounting.read` |

Disabling new exposure must not erase or conceal existing records. Provider webhooks must remain idempotent and persisted even when acquisition is disabled.

## Provider and domain controls

The catalog includes live-routing controls for Paystack and Interswitch; provider controls for identity verification, SMS, weather, satellite imagery, and AI; institutional dashboards for government and NGO tenants; and full farm ERP operations.

Provider credentials and a flag are both required. Enabling a flag without valid provider configuration must produce a controlled configuration error and must never silently fall back from a live transaction to fake success.

## Administration

The planned administration API and UI must provide:

- read-only catalog and effective-decision views;
- global, jurisdiction, and tenant overrides;
- effective dates and expiry;
- validated JSON configuration;
- mandatory reason and maker-checker approval for regulated or live-provider changes;
- emergency-stop controls restricted to incident-authorized operators;
- immutable audit history.

Direct client access to flag tables is prohibited. RLS is enabled with no `anon` or `authenticated` grants; only trusted backend service operations may read or change flag state.

## Test requirements

Tests must prove precedence, environment and effective-date filtering, tenant isolation, unknown-key failure, storage failure modes, emergency-stop priority, configuration merging, middleware denial, audit creation, authorization, and the separation between new exposure and servicing.
