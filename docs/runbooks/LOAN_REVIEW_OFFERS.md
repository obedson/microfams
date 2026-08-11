# CRD-03 Credit Review and Offer Runbook

## Scope

CRD-03 takes a CRD-02 application from `credit_review` through an independent manual decision.
An approval atomically issues a versioned offer; a decline records reviewer evidence and a
versioned adverse notice. The borrower can accept only the exact current offer before expiry.
This increment does not generate contractual schedule rows, move money, create a receivable,
disburse funds, or collect repayments.

## Controls

- Manual approval, decline, offer revision, and offer acceptance require
  `financial.loans.originate`. Disabling origination therefore blocks new credit exposure.
- Authorized reads use `financial.loans.read`. Expiry, withdrawal, and adverse-review servicing
  use `financial.loans.service_existing` so customer-protection paths remain available.
- Offer issuance, revision, decline, and expiry require the tenant-scoped
  `financial.loans.review` permission. The reviewer cannot be the applicant.
- Group and organization applicants must retain `financial.loans.apply_on_behalf` authority when
  accepting an offer.
- Offer principal cannot exceed the requested amount and all terms must stay inside the exact
  pinned product version. Rates, fees, repayment frequency, interest method, allocation order,
  collateral, guarantee, grace, penalty, and disclosure rules are copied from that version.
- Non-delinquency fees are recalculated from the product rules. Flat and simple interest totals
  must match the deterministic 365-day calculation. Reducing-balance interest must be positive
  and cannot exceed the equivalent simple-interest cap; the later exact schedule must reconcile
  to the accepted aggregate without increasing it.
- Money uses integer minor units. Total repayable must equal principal plus total interest plus
  total fees.
- Every offer has a canonical terms snapshot and SHA-256 hash. A material change supersedes the
  prior offer and creates a new immutable version and decision; it never edits accepted terms.
- Acceptance records the exact offer hash plus a versioned acceptance text hash. An expired,
  superseded, withdrawn, wrong-tenant, or hash-mismatched offer cannot be accepted.

## Lifecycle

1. A permitted reviewer reads the tenant queue from `GET /api/credit/admin/applications`.
2. Approval or revision uses `POST /api/credit/admin/applications/:applicationId/offers`.
3. Manual decline uses `POST /api/credit/admin/applications/:applicationId/decline` and creates an
   adverse notice eligible for the existing independent review path.
4. The applicant accepts through
   `POST /api/credit/applications/:applicationId/offers/:offerId/accept`, supplying the displayed
   offer hash and exact acceptance version/hash.
5. An elapsed offer is serviced through
   `POST /api/credit/admin/applications/:applicationId/offers/:offerId/expire`, which returns the
   application to `credit_review` for a fresh decision.
6. Before acceptance, the applicant may withdraw through the existing withdrawal endpoint; any
   current offer becomes `withdrawn` atomically.

## Adverse notice

CRD-03 manual declines use notice version `CRD-03.ADVERSE.1`. Its canonical content marker is:

`CRD-03 manual credit decline notice: reasons, review right, and support route.`

The stored SHA-256 hash is
`d4aa7309b172aa88fdbc15170d77dc201a8200ca43e684cd1e4c4409c57b3291`. Reason codes and the
reviewer's explanation are stored separately as immutable decision evidence.

## Recovery and rollback

Commands are tenant-idempotent and application-serialized. Reuse an idempotency key only with
identical facts. A timeout before a response can be retried safely. Never edit offer, decision,
event, or acceptance evidence directly; issue a revised offer or use the documented lifecycle
command. Rollback removes new routes while retaining durable offer and decision records for
authorized reads and servicing.

## Credentials and next increment

CRD-03 requires no new provider credential and cannot move money. Live origination still requires
recorded lending authority, provider/lender approval, disclosure approval, decision-policy owner,
data-protection review, support owner, and controlled test-tenant sign-off. CRD-04 must generate a
schedule that exactly reconciles to the accepted aggregate before conditions precedent,
disbursement, receivables, repayments, delinquency, restructuring, or write-off are enabled.
