# CRD-01 Loan Product Governance Runbook

## Scope

CRD-01 governs the rules that later application, underwriting, offer, schedule, servicing,
delinquency, restructuring, and write-off workflows must consume. It does not originate or
disburse credit. A product becoming active means its rule and disclosure version is approved;
it does not mean a lender/provider or live money rail is certified.

## Controls

- `financial.loans.read` is servicing-safe and exposes only active products to active tenant members.
- `financial.loans.configure` fails closed and protects product administration at the API and worker boundary.
- `financial.loans.originate` remains separately disabled until compliance and provider readiness are recorded.
- `financial.loans.configure` permission is tenant-scoped. Product makers cannot approve their own version.
- Product terms use integer minor units and basis points. Disclosures are bound by version and SHA-256 hash.
- Revisions create a new immutable version. Approval retires the prior active version atomically; historical facts remain readable.
- External lender configuration stores only a non-secret provider code and display name. Credentials belong in the deployment secret manager.

## Operating sequence

1. Enable `financial.loans.configure` for the controlled tenant and environment.
2. A tenant credit administrator creates a complete product draft through `POST /api/credit/products`.
3. A permitted maker submits the version through `POST /api/credit/products/:productId/submit`.
4. A different permitted actor approves through `POST /api/credit/products/:productId/approve`.
5. Active tenant members can discover the exact active rule snapshot through `GET /api/credit/products`.
6. To change material terms, create a revision through `POST /api/credit/products/:productId/versions`, then repeat submit and independent approval.

## Recovery and rollback

The migration is additive. Application rollback removes the credit route while leaving approved
history intact. Do not delete or edit product/version/event rows. A rejected command is safe to
retry with the same idempotency key and identical facts. A reused key with different facts fails.
If activation is unsafe, disable `financial.loans.configure` and `financial.loans.originate`;
keep `financial.loans.read` and `financial.loans.service_existing` available for customer protection.

## Remaining live-enablement evidence

Before real origination, record jurisdictional compliance approval, licensed lender/provider,
adapter and credential configuration, disclosure/legal review, credit-policy owner, underwriting
and adverse-action review, sandbox certification, reconciliation sign-off, support ownership, and
controlled live smoke-test evidence. No credential is required for CRD-01 itself.
