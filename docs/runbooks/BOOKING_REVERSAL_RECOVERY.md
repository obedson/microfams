# Booking reversal recovery

The Paystack payment webhook is the booking reversal intake. It accepts only
the provider's signed raw payload, records an idempotent provider event, and
routes a reversed booking payment through reverse_inbound_payment. The booking
recovery trigger preserves original payment and payout evidence, classifies
escrow, unpaid, and post-payout exposure, and posts balanced cross-tenant
recovery journals. It never debits an unrelated wallet.

## Incident handling

1. Disable financial.payments.service_existing or the provider webhook
   submission flag before investigating a provider or ledger incident.
2. Verify the provider event id, raw payload hash, payment, settlement contract,
   recovery case, and journal entries. Replayed events must return the existing
   receipt and must not create a second reversal.
3. Use the booking recovery maker-checker commands for supplier repayment,
   provider recovery, insurance, bounded future-settlement offsets, or
   write-offs. Record evidence references and decision reasons.
4. Run booking reversal schema, recovery API, balance, and tenant-isolation
   checks before restoring service.

## Rollback and recovery

Do not delete or directly update payment reversals, recovery cases, recovery
events, payout evidence, or posted journals. If deployment is rolled back,
keep the migration installed and disable the affected feature flag. Resume by
replaying only the provider event with its original idempotency key after
service and reconciliation checks pass. Correct financial outcomes with
approved reversal or compensating commands, never by unrelated-wallet debit.