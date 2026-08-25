# Escrow Contracts

Escrow contract creation and activation are tenant-admin operations behind the `financial.escrow.create` backend feature flag. Every command requires an idempotency key and retains terms, milestones, release rules, arbiters, dispute-window, and expiry evidence.

## Create and activate

1. Confirm the tenant, payer, beneficiary, currency, integer minor-unit amount, purpose, milestones, release rules, authorized arbiters, dispute window, and expiry.
2. Submit a draft through `POST /api/escrow/contracts`; preserve the contract ID and audit evidence.
3. Review terms and release evidence independently.
4. Activate through `POST /api/escrow/contracts/:contractId/activate` with a new idempotency key.
5. Verify the contract state and retain the audit record.

Disable `financial.escrow.create` to prevent new drafts and activations while preserving records. Never edit escrow balances or delete contract evidence; use approved reversals or compensating postings.
