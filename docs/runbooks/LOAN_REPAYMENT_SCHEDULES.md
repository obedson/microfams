# CRD-04 Contractual Repayment Schedule Runbook

## Scope

CRD-04 converts one accepted CRD-03 offer into one immutable contractual schedule. It preserves
the exact accepted principal, interest, fees, total repayable, currency, frequency, interest
method, tenor, grace period, offer hash, allocation algorithm, and every scheduled row. It does
not pass conditions precedent, confirm disbursement, create a receivable, move money, collect a
repayment, assess arrears, restructure, or write off a loan.

## Timing model

Schedule dates are stored as days after confirmed disbursement. This avoids displaying fabricated
calendar due dates before a provider has confirmed that the borrower received funds. V1 frequency
conventions are versioned by `CRD-04.SCHEDULE.1`: weekly 7 days, fortnightly 14 days, monthly 30
days, quarterly 91 days, and bullet at the accepted tenor. Grace days are added to each repayment
offset. The final repayment offset always ends at accepted tenor plus grace.

A later disbursement increment may materialize calendar dates only by adding the confirmed
disbursement date to these offsets. It must not alter the scheduled amounts or schedule hash.

## Amount allocation

- Money remains integer minor units; no floating-point arithmetic is used.
- Principal is allocated equally, with the indivisible residual in the final repayment.
- Flat, simple, and zero-interest totals are distributed evenly, with single-minor-unit residuals
  assigned from the earliest repayment forward.
- Reducing-balance interest is allocated in proportion to each period's opening principal. Floor
  residuals are assigned from the earliest repayment forward, preserving a non-increasing series.
- Non-capitalized application or disbursement fees form one sequence-zero upfront item. Remaining
  accepted fees are distributed across repayment rows.
- The database rejects generation unless row totals exactly equal the accepted offer's principal,
  interest, fees, and total repayable. One contractual schedule is allowed per accepted offer.

## Controls and API

- Generate through
  `POST /api/credit/admin/applications/:applicationId/offers/:offerId/schedule`.
- Generation requires `financial.loans.service_existing` plus the tenant-scoped
  `financial.loans.review` permission. The generator cannot be the applicant.
- Applicant and authorized review histories expose the immutable schedule and installments through
  the existing application-list endpoints under `financial.loans.read`.
- The schedule command is application-serialized and tenant-idempotent. Reuse a key only with the
  identical actor, application, offer, accepted offer hash, and algorithm version.
- Service roles may read schedule evidence but cannot directly insert, update, or delete schedules
  or installments. Every successful generation has an application event and tenant audit record.

## Recovery and rollback

A timeout may be retried with the original idempotency key. A rejected generation writes no partial
schedule. Never repair schedule rows manually: investigate the accepted offer and algorithm, then
retry before a schedule exists. Application rollback removes the route while retaining authorized
read access to durable schedules. Database rollback must preserve generated contractual evidence.

## Credentials and next increment

CRD-04 requires no new provider credential and performs no live money movement. CRD-05 should add
versioned conditions precedent and provider-neutral disbursement orchestration. It must use the
confirmed provider disbursement date to materialize due dates from CRD-04 offsets, create balanced
loan receivable accounting only on confirmed success, and retain recovery/reconciliation paths for
timeouts, failures, duplicates, and late provider events.
