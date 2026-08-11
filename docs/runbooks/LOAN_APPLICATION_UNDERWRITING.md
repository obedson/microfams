# CRD-02 Loan Application and Underwriting Runbook

## Scope

CRD-02 accepts applications against an active CRD-01 product version, preserves the exact
product and disclosure facts, performs deterministic product-eligibility, representative-
identity, and affordability screening, and records explainable adverse outcomes. It does not
create an offer, repayment schedule, disbursement, receivable, or provider money movement.

## Controls

- `financial.loans.originate` fails closed for new drafts and submissions.
- `financial.loans.read` exposes an applicant's own history; actors with the tenant-scoped
  `financial.loans.review` permission can read the tenant review queue.
- `financial.loans.service_existing` keeps withdrawal and adverse human review available when
  new origination is disabled.
- Individual applicants can apply only for themselves. Group and organization applications
  require `financial.loans.apply_on_behalf` and a tenant-owned active borrower.
- Every application pins the active product/version, disclosure version/hash, declaration
  version/hash, and the complete product rule snapshot.
- Input money is stored in integer minor units. Evidence fields accept reference identifiers,
  not raw bank details, identity numbers, provider tokens, or uploaded document contents.
- Automated decisions preserve input facts, rule/model version, result, reason codes, and the
  exact rules used. Decision evidence is append-only and engine-controlled.
- An automated decline issues a versioned adverse notice. The applicant may request human
  review; an independently authorized reviewer may uphold it or reopen the application into
  `credit_review`, with the override and reason recorded immutably.

## Application sequence

1. Read an active product and its exact disclosure through `GET /api/credit/products`.
2. Create a draft with `POST /api/credit/applications` while origination is enabled.
3. Submit with `POST /api/credit/applications/:applicationId/submit`.
4. The atomic screening command records product eligibility, identity requirements, and
   affordability results. Passing and manual-review cases enter `credit_review`; rule failures
   enter `declined` with understandable reason codes and a human-review route.
5. A declined applicant requests review through
   `POST /api/credit/applications/:applicationId/adverse-review`.
6. An independent permitted reviewer decides through
   `POST /api/credit/admin/applications/:applicationId/adverse-review/decide`.
7. An applicant may withdraw a pre-offer application through
   `POST /api/credit/applications/:applicationId/withdraw`.

## Affordability estimate

The automated screen uses the product's effective annual cost, a 365-day basis, and 30-day
monthly-equivalent periods to estimate the new monthly obligation. It compares that estimate
plus declared existing monthly debt with verified monthly net income. Missing or unsupported
affordability rule dimensions route to manual `credit_review`; they never produce a fabricated
approval. Later schedule generation must use the exact offered terms and may not reuse this
screening estimate as a contractual instalment.

## Recovery and rollback

All commands are tenant-idempotent. Reuse the same key only with identical facts. Disable
`financial.loans.originate` to stop new exposure while leaving `read` and `service_existing`
available. Application, decision, adverse-review, event, and audit rows must not be edited or
deleted manually. Application rollback removes the routes but retains all durable evidence.

## Credentials and later enablement

CRD-02 needs no new provider credential. Identity screening consumes already validated,
provider-neutral identity evidence. Before live origination, record the jurisdictional lending
approval, licensed lender/provider, disclosures, decision-policy owner, data-protection review,
provider certification, reconciliation owner, support owner, and controlled test-tenant sign-off.
