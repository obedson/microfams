-- BS-09A provider reversal classification and post-payout recovery intake.
DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009801';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009802';
  contract booking_settlement_contracts;
  payment payments;
  reversal payment_reversals;
  recovery booking_recovery_cases;
BEGIN
  SELECT * INTO contract FROM booking_settlement_contracts
  WHERE organization_id = customer_org
    AND provider_organization_id = provider_org
  ORDER BY created_at DESC LIMIT 1;
  IF contract.id IS NULL THEN
    RAISE EXCEPTION 'BS-09 fixture settlement contract is missing';
  END IF;
  SELECT * INTO payment FROM payments WHERE id = contract.payment_id;
  reversal := reverse_inbound_payment(
    payment.id, 'BS09-PROVIDER-REVERSAL-001',
    'BS09-REVERSAL-' || replace(payment.id::TEXT, '-', ''),
    payment.amount_minor, 'Provider confirmed booking chargeback.',
    NOW()
  );
  SELECT * INTO recovery FROM booking_recovery_cases
  WHERE payment_reversal_id = reversal.id;
  IF recovery.id IS NULL
    OR recovery.reversed_amount_minor <> payment.amount_minor
    OR recovery.escrow_recovered_minor
      + recovery.unpaid_compensated_minor
      + recovery.recoverable_amount_minor <> payment.amount_minor
    OR recovery.recoverable_amount_minor <= 0
    OR recovery.state <> 'open'
    OR recovery.customer_journal_entry_id IS NULL
    OR recovery.provider_journal_entry_id IS NULL
  THEN RAISE EXCEPTION 'provider reversal was not classified exactly'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM booking_recovery_events
    WHERE recovery_case_id = recovery.id
      AND event_type = 'recovery_required'
      AND (evidence_snapshot->>'automatic_wallet_debit_permitted')::BOOLEAN = FALSE
  ) THEN RAISE EXCEPTION 'post-payout recovery did not forbid automatic wallet debit'; END IF;
  IF (SELECT count(*) FROM journal_lines
      WHERE journal_entry_id = recovery.customer_journal_entry_id) < 2
    OR (SELECT COALESCE(sum(amount_minor) FILTER (WHERE side = 'debit'), 0)
          <> COALESCE(sum(amount_minor) FILTER (WHERE side = 'credit'), 0)
        FROM journal_lines WHERE journal_entry_id = recovery.customer_journal_entry_id)
    OR (SELECT COALESCE(sum(amount_minor) FILTER (WHERE side = 'debit'), 0)
          <> COALESCE(sum(amount_minor) FILTER (WHERE side = 'credit'), 0)
        FROM journal_lines WHERE journal_entry_id = recovery.provider_journal_entry_id)
  THEN RAISE EXCEPTION 'reversal classification journals are not balanced'; END IF;
  IF (SELECT state FROM booking_settlement_contracts WHERE id = contract.id) <> 'reversed'
  THEN RAISE EXCEPTION 'reversed booking settlement state was not preserved'; END IF;
END $$;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_recovery_cases', 'INSERT')
    OR has_table_privilege('service_role', 'booking_recovery_cases', 'UPDATE')
    OR has_table_privilege('authenticated', 'booking_recovery_cases', 'SELECT')
  THEN RAISE EXCEPTION 'booking recovery evidence exposes direct mutation or reads'; END IF;
END $$;
