# Escrow Contracts

Escrow contract creation and activation are tenant-admin operations behind the `financial.escrow.create` backend feature flag. Every command requires an idempotency key and retains terms, milestones, release rules, arbiters, dispute-window, and expiry evidence.

## Create and activate

1. Confirm the tenant, payer, beneficiary, currency, integer minor-unit amount, purpose, milestones, release rules, authorized arbiters, dispute window, and expiry.
2. Submit a draft through `POST /api/escrow/contracts`; preserve the contract ID and audit evidence.
3. Review terms and release evidence independently.
4. Activate through `POST /api/escrow/contracts/:contractId/activate` with a new idempotency key.
5. Verify the contract state and retain the audit record.

## Approved release execution (ESC-05)

This runbook covers ESC-05 exactly-once approved escrow release execution into beneficiary wallets with balanced journals and terminal-state evidence.

Execute only an independently approved release request for an active, funded contract. The execution command must use a tenant-scoped idempotency key, lock the request and contract, revalidate the approved amount and beneficiary, debit the canonical escrow funds-held liability, credit the beneficiary wallet liability, and persist one balanced journal plus terminal release evidence. A replay returns the existing outcome; a changed key or facts must fail without another posting.

Before closing an incident, verify the request is terminal, the contract released amount advanced exactly once, both journal legs use the contract currency and minor units, and the beneficiary wallet balance derives from the journal. Quarantine unknown or partial outcomes and reconcile the request, contract, journal, and wallet facts under the same tenant. Never edit a posted journal or force a terminal state manually. Disable new escrow release commands during recovery while preserving existing contracts and servicing evidence; correct failures with an approved forward migration or compensating entry.

Disable `financial.escrow.create` to prevent new drafts and activations while preserving records. Never edit escrow balances or delete contract evidence; use approved reversals or compensating postings.
