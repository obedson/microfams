# CRD-05 Loan Conditions and Disbursement Runbook

## Scope

CRD-05 takes one accepted CRD-03 offer and its CRD-04 contractual schedule through versioned
conditions precedent, verified destination approval, provider submission, and confirmed loan
activation. It creates no receivable, active contract, or calendar due date before the provider
confirms success. It does not collect repayments, assess arrears, restructure, or write off debt.

## Conditions precedent

- `CRD-05.CONDITIONS.1` snapshots the accepted offer hash, schedule hash, exact offer condition
  codes, maker-checker rule, destination requirement, and provider-confirmation requirement.
- Each condition has append-only evidence attempts. Rejection preserves the attempt and permits a
  new submission; satisfaction requires a different actor from the submitter and borrower.
- The condition set becomes `ready` only when every accepted-offer condition is satisfied. An
  offer with no stated condition codes creates a documented, immediately ready empty set.
- Initialization and decisions require `financial.loans.disburse`; borrower evidence submission
  uses the servicing path. The applicant cannot initialize or approve their own conditions.

## Destination control

The borrower proposes a destination through the configured payout adapter's name-enquiry path.
Clear account data is encrypted with AES-256-GCM using
`LOAN_DISBURSEMENT_DESTINATION_ENCRYPTION_KEY`. Database reads and API responses expose only a
fingerprint, mask, masked account name, provider/environment, and hashed verification facts. A
different permitted actor must verify or reject the proposal before disbursement.

Never log or manually query destination ciphertext. Rotate the key only through an approved
reencryption procedure; replacing it without reencrypting current proposals makes them unusable.

## Provider and accounting lifecycle

1. `POST .../conditions` initializes the immutable condition set.
2. The borrower submits evidence; an independent operator satisfies or rejects each condition.
3. The borrower proposes a provider-validated destination; an independent operator verifies it.
4. `POST .../disbursements` revalidates the accepted offer, contractual schedule, ready condition
   set, verified destination, actor separation, provider identity, and reconciliation blocks.
5. The shared payout adapter submits the exact accepted principal. A timeout remains `processing`
   and is recovered by webhook or the servicing-safe sync endpoint.
6. Confirmed success atomically debits the tenant's loan-principal receivable, credits provider
   clearing, activates `CRD-05.CONTRACT.1`, and copies CRD-04 offsets into calendar dates using
   the confirmed provider date. The journal, contract, due rows, event, and audit record commit or
   roll back together.

Contractual interest and fees remain separately disclosed but are not posted as receivables at
disbursement; later servicing accrues or recognizes them under their approved timing rules.

## Failure, retry, and late success

A confirmed failure posts no journal, creates no contract, returns the application to `accepted`,
and permits a new numbered attempt. Duplicate provider callbacks and status queries are idempotent.
A success received after a terminal failure is never auto-posted: it creates a tenant-scoped
`late_provider_success` reconciliation exception, quarantines the application in
`disbursement_pending`, and blocks another attempt until the exception is resolved.

Application rollback may remove command routes while retaining reads, callbacks, synchronization,
and reconciliation. Database rollback must retain durable condition, destination, payout,
contract, journal, due-date, and exception evidence.

## Flags, permissions, and credentials

- New transfer: `financial.loans.disburse` plus the matching tenant permission.
- Evidence, decisions, destination verification, sync, and reconciliation:
  `financial.loans.service_existing`; controlled decisions also require the disbursement permission.
- Reads: `financial.loans.read` through existing application history.
- Live provider routing additionally requires its provider flag, credentials, approval evidence,
  beneficiary validation, webhook verification, settlement configuration, and reconciliation
  certification. Deterministic adapters are forbidden in production.

CRD-06 should implement idempotent repayment intake and allocation, principal/interest/fee
receivable servicing, partial payments, payoff quotes, statements, and reconciliation before
delinquency classification is enabled.
