-- BS-09B maker-checker recovery, approved offsets, write-off, and late success.
DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009801';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009802';
  maker CONSTANT UUID := '00000000-0000-4000-8000-000000009821';
  checker CONSTANT UUID := '00000000-0000-4000-8000-000000009822';
  recovery booking_recovery_cases;
  agreement JSONB;
  action JSONB;
  agreement_id UUID;
  action_id UUID;
  release_id UUID;
  failed_payout payouts;
  late_success JSONB;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (maker, 'booking-recovery-maker@example.test', 'not-a-real-password',
      'Booking Recovery Maker', 'admin'),
    (checker, 'booking-recovery-checker@example.test', 'not-a-real-password',
      'Booking Recovery Checker', 'admin');
  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, joined_at
  ) VALUES
    (customer_org, maker, 'finance_manager',
      ARRAY['financial.reconciliation.manual', 'financial.reconciliation.approve'], 'active', NOW()),
    (customer_org, checker, 'finance_manager',
      ARRAY['financial.reconciliation.approve'], 'active', NOW());

  SELECT * INTO recovery FROM booking_recovery_cases
  WHERE organization_id = customer_org AND recoverable_amount_minor > 3000
  ORDER BY created_at DESC LIMIT 1;
  SELECT item.settlement_release_id INTO release_id
  FROM booking_supplier_payout_items item
  JOIN payouts payout ON payout.id = item.payout_id
  WHERE item.settlement_contract_id = recovery.settlement_contract_id
    AND payout.state = 'cancelled'
  ORDER BY item.created_at DESC LIMIT 1;

  agreement := propose_booking_recovery_offset_agreement(
    customer_org, provider_org, maker, recovery.currency, 5000,
    NOW() - INTERVAL '1 hour', NOW() + INTERVAL '30 days',
    'Permit a bounded offset against a traceable future supplier settlement.',
    'approved-agreement-evidence-001', 'booking-offset-agreement-001'
  );
  agreement_id := (agreement->>'id')::UUID;
  BEGIN
    PERFORM decide_booking_recovery_offset_agreement(
      agreement_id, customer_org, maker, TRUE,
      'Maker must not approve the offset agreement.'
    );
    RAISE EXCEPTION 'offset agreement maker approved their own request';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MAKER_CHECKER_REQUIRED%' THEN RAISE; END IF;
  END;
  agreement := decide_booking_recovery_offset_agreement(
    agreement_id, customer_org, checker, TRUE,
    'Independent finance review approves the bounded offset agreement.'
  );
  IF agreement->>'state' <> 'active'
  THEN RAISE EXCEPTION 'offset agreement was not activated'; END IF;

  action := propose_booking_recovery_action(
    recovery.id, customer_org, maker, 'future_settlement_offset', 1000,
    agreement_id, release_id, 'offset-release-evidence-001',
    'Offset a bounded amount against the selected unpaid supplier release.',
    'booking-recovery-offset-action-001'
  );
  action_id := (action->>'id')::UUID;
  action := decide_booking_recovery_action(
    action_id, customer_org, checker, TRUE,
    'Independent finance review approves the settlement offset.'
  );
  IF action->>'state' <> 'approved'
    OR action->>'customer_journal_entry_id' IS NULL
    OR action->>'provider_journal_entry_id' IS NULL
  THEN RAISE EXCEPTION 'approved recovery offset was not posted'; END IF;

  action := propose_booking_recovery_action(
    recovery.id, customer_org, maker, 'supplier_repayment', 1000,
    NULL, NULL, 'supplier-repayment-evidence-001',
    'Record confirmed supplier repayment against the recovery obligation.',
    'booking-recovery-repayment-001'
  );
  action := decide_booking_recovery_action(
    (action->>'id')::UUID, customer_org, checker, TRUE,
    'Independent finance review confirms the repayment evidence.'
  );
  IF action->>'state' <> 'approved'
  THEN RAISE EXCEPTION 'supplier repayment was not approved'; END IF;

  action := propose_booking_recovery_action(
    recovery.id, customer_org, maker, 'writeoff', 500,
    NULL, NULL, 'writeoff-evidence-001',
    'Write off the evidenced unrecoverable portion under finance control.',
    'booking-recovery-writeoff-001'
  );
  action := decide_booking_recovery_action(
    (action->>'id')::UUID, customer_org, checker, TRUE,
    'Independent finance review approves the bounded loss write-off.'
  );
  IF action->>'state' <> 'approved'
    OR (SELECT loss_amount_minor FROM booking_recovery_cases
        WHERE id = recovery.id) <> 500
  THEN RAISE EXCEPTION 'maker-checker write-off was not posted'; END IF;

  SELECT payout.* INTO failed_payout
  FROM payouts payout
  JOIN booking_supplier_payout_items item ON item.payout_id = payout.id
  WHERE item.settlement_contract_id = recovery.settlement_contract_id
    AND payout.state = 'failed'
  ORDER BY payout.created_at LIMIT 1;
  late_success := record_booking_late_payout_success(
    failed_payout.id, failed_payout.organization_id, 'LATE-SUCCESS-BS09-001',
    failed_payout.amount_minor, failed_payout.currency,
    failed_payout.beneficiary_fingerprint, failed_payout.provider_name,
    failed_payout.provider_environment,
    jsonb_build_object('provider_event_hash', repeat('e', 64))
  );
  IF late_success->>'state' <> 'open'
    OR (SELECT state FROM payouts WHERE id = failed_payout.id) <> 'failed'
    OR NOT (late_success->'evidence_snapshot'->>'recorded_without_repaying')::BOOLEAN
  THEN RAISE EXCEPTION 'late payout success was not quarantined safely'; END IF;
END $$;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_recovery_actions', 'INSERT')
    OR has_table_privilege('service_role', 'booking_recovery_actions', 'UPDATE')
    OR has_table_privilege('authenticated', 'booking_recovery_actions', 'SELECT')
  THEN RAISE EXCEPTION 'booking recovery servicing exposes direct table access'; END IF;
END $$;
