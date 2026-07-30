DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009801';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009802';
  provider_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009812';
  checker CONSTANT UUID := '00000000-0000-4000-8000-000000009814';
  correlation CONSTANT UUID := '00000000-0000-4000-8000-000000009851';
  second_release_id CONSTANT UUID := '00000000-0000-4000-8000-000000009852';
  second_source_id CONSTANT UUID := '00000000-0000-4000-8000-000000009853';
  third_release_id CONSTANT UUID := '00000000-0000-4000-8000-000000009854';
  third_source_id CONSTANT UUID := '00000000-0000-4000-8000-000000009855';
  contract booking_settlement_contracts;
  first_release booking_settlement_releases;
  beneficiary JSONB;
  changed_beneficiary JSONB;
  payout_result JSONB;
  rule_result JSONB;
  payout payouts;
  second_release JSONB;
  third_release JSONB;
  beneficiary_id UUID;
  changed_beneficiary_id UUID;
  payout_id UUID;
  rule_id UUID;
  projection JSONB;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES (
    checker, 'booking-payout-checker@example.test', 'not-a-real-password',
    'Booking Payout Checker', 'admin'
  );
  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, joined_at
  ) VALUES (
    provider_org, checker, 'admin',
    ARRAY[
      'booking.settlements.release',
      'financial.payouts.create',
      'financial.payouts.approve',
      'financial.payouts.rules.approve'
    ],
    'active', NOW()
  );

  SELECT * INTO contract FROM booking_settlement_contracts
  WHERE organization_id = customer_org
    AND provider_organization_id = provider_org
  ORDER BY created_at DESC LIMIT 1;
  SELECT * INTO first_release FROM booking_settlement_releases
  WHERE settlement_contract_id = contract.id
    AND supplier_amount_minor > 0
  ORDER BY created_at LIMIT 1;
  IF first_release.id IS NULL
    OR (SELECT change_window_hours
        FROM booking_payout_destination_change_rules
        WHERE organization_id = provider_org AND status = 'active') <> 24
  THEN RAISE EXCEPTION 'BS-08 prerequisites or default rule are missing'; END IF;
  PERFORM apply_payment_refund_result(
    (
      SELECT refund.id
      FROM payment_refunds AS refund
      WHERE refund.payment_id = contract.payment_id
        AND refund.state = 'created'
      ORDER BY refund.created_at
      LIMIT 1
    ),
    'DET-BS08-REFUND-SUCCESS', 'succeeded', NULL, NULL
  );

  beneficiary := register_booking_payout_beneficiary(
    provider_org, provider_owner, provider_owner,
    repeat('x', 80), repeat('a', 64), '******1111', 'Synt**** Owner',
    'deterministic', 'deterministic', 'DET-VERIFY-1111',
    'booking-beneficiary-register-001'
  );
  beneficiary_id := (beneficiary->>'beneficiary_id')::UUID;
  IF beneficiary->>'state' <> 'verified'
    OR beneficiary::TEXT LIKE '%destination_ciphertext%'
  THEN RAISE EXCEPTION 'initial verified beneficiary projection is unsafe'; END IF;

  payout_result := create_booking_supplier_payout(
    first_release.id, provider_org, provider_owner, beneficiary_id,
    'deterministic', 'deterministic',
    'booking-supplier-payout-create-001', correlation
  );
  payout_id := (payout_result->>'payout_id')::UUID;
  SELECT * INTO payout FROM payouts WHERE id = payout_id;
  IF payout.source_type <> 'booking_settlement'
    OR payout.withdrawal_request_id IS NOT NULL
    OR payout.reservation_id IS NOT NULL
    OR payout.amount_minor <> first_release.supplier_amount_minor
  THEN RAISE EXCEPTION 'booking payout did not extend the canonical payout source safely'; END IF;
  payout := mark_payout_submitted(
    payout.id, repeat('b', 64), 'DET-BSP-FAIL-1', TRUE
  );
  IF payout.state <> 'processing'
    OR (SELECT item.state FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id) <> 'processing'
  THEN RAISE EXCEPTION 'booking payout timeout did not remain recoverable'; END IF;
  payout := fail_booking_supplier_payout(
    payout.id, 'DECLINED', 'Synthetic provider decline'
  );
  IF payout.state <> 'failed'
    OR (SELECT item.state FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id) <> 'restored'
    OR payout.success_journal_entry_id IS NOT NULL
  THEN RAISE EXCEPTION 'failed booking payout did not restore supplier payable'; END IF;

  rule_result := propose_booking_payout_change_rule(
    provider_org, provider_owner, 2, 48, NOW(),
    'Extend the independently reviewed destination-change control window.',
    'booking-payout-change-rule-002'
  );
  rule_id := (rule_result->>'rule_id')::UUID;
  rule_result := decide_booking_payout_change_rule(
    rule_id, provider_org, checker, TRUE,
    'Independent review approves the replacement control window.',
    'booking-payout-change-rule-decision-002'
  );
  IF rule_result->>'state' <> 'active'
  THEN RAISE EXCEPTION 'versioned payout change rule was not activated'; END IF;

  second_release := apply_booking_release_allocation(
    contract.id, provider_owner, second_release_id, 'dispute_resolution',
    second_source_id, 10000, 0, 'booking-second-release-001', correlation
  );
  IF (second_release->'release'->>'supplier_amount_minor')::BIGINT <> 10000
  THEN RAISE EXCEPTION 'second traceable supplier release was not created'; END IF;

  changed_beneficiary := register_booking_payout_beneficiary(
    provider_org, provider_owner, provider_owner,
    repeat('y', 80), repeat('c', 64), '******2222', 'Synt**** Owner',
    'deterministic', 'deterministic', 'DET-VERIFY-2222',
    'booking-beneficiary-register-002'
  );
  changed_beneficiary_id := (changed_beneficiary->>'beneficiary_id')::UUID;
  IF changed_beneficiary->>'state' <> 'pending_approval'
    OR NOT (changed_beneficiary->>'requires_independent_approval')::BOOLEAN
    OR (SELECT (change_rule_snapshot->>'change_window_hours')::INTEGER
        FROM booking_payout_beneficiaries
        WHERE id = changed_beneficiary_id) <> 48
    OR NOT EXISTS (
      SELECT 1 FROM booking_settlement_holds
      WHERE settlement_contract_id = contract.id
        AND hold_type = 'risk' AND state = 'active'
        AND source_id = changed_beneficiary_id::TEXT
    )
  THEN RAISE EXCEPTION 'destination change did not create approval and risk controls'; END IF;
  BEGIN
    PERFORM decide_booking_payout_beneficiary(
      changed_beneficiary_id, provider_org, provider_owner, TRUE,
      'The maker cannot approve the destination change.',
      'booking-beneficiary-decision-maker'
    );
    RAISE EXCEPTION 'beneficiary maker unexpectedly approved the change';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MAKER_CHECKER_REQUIRED%' THEN RAISE; END IF;
  END;
  changed_beneficiary := decide_booking_payout_beneficiary(
    changed_beneficiary_id, provider_org, checker, TRUE,
    'Independent review confirms the verified replacement destination.',
    'booking-beneficiary-decision-001'
  );
  IF changed_beneficiary->>'state' <> 'verified'
    OR (SELECT state FROM booking_payout_beneficiaries
        WHERE id = beneficiary_id) <> 'retired'
    OR EXISTS (
      SELECT 1 FROM booking_settlement_holds
      WHERE source_id = changed_beneficiary_id::TEXT AND state = 'active'
    )
  THEN RAISE EXCEPTION 'approved beneficiary change did not release controls'; END IF;

  payout_result := create_booking_supplier_payout(
    second_release_id, provider_org, provider_owner, changed_beneficiary_id,
    'deterministic', 'deterministic',
    'booking-supplier-payout-create-002', correlation
  );
  payout_id := (payout_result->>'payout_id')::UUID;
  payout := mark_payout_submitted(
    payout_id, repeat('d', 64), 'DET-BSP-SUCCESS-1', FALSE
  );
  BEGIN
    PERFORM succeed_booking_supplier_payout(
      payout.id, payout.internal_reference, 'DET-BSP-SUCCESS-1',
      payout.amount_minor + 1, payout.currency, repeat('c', 64),
      provider_org, payout.provider_name, payout.provider_environment
    );
    RAISE EXCEPTION 'changed provider success unexpectedly posted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH%'
    THEN RAISE; END IF;
  END;
  payout := succeed_booking_supplier_payout(
    payout.id, payout.internal_reference, 'DET-BSP-SUCCESS-1',
    payout.amount_minor, payout.currency, repeat('c', 64),
    provider_org, payout.provider_name, payout.provider_environment
  );
  IF payout.state <> 'succeeded'
    OR (SELECT item.state FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id) <> 'paid'
    OR (SELECT customer_journal_entry_id IS NULL
          OR provider_journal_entry_id IS NULL
        FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id)
  THEN RAISE EXCEPTION 'successful booking payout did not post exact traceable journals'; END IF;

  third_release := apply_booking_release_allocation(
    contract.id, provider_owner, third_release_id, 'dispute_resolution',
    third_source_id, 5000, 0, 'booking-third-release-001', correlation
  );
  payout_result := create_booking_supplier_payout(
    third_release_id, provider_org, provider_owner, changed_beneficiary_id,
    'deterministic', 'deterministic',
    'booking-supplier-payout-create-003', correlation
  );
  payout_id := (payout_result->>'payout_id')::UUID;
  payout := cancel_booking_supplier_payout(
    payout_id, provider_org, provider_owner,
    'Operator cancelled before provider submission.',
    'booking-supplier-payout-cancel-003'
  );
  IF payout.state <> 'cancelled'
    OR (SELECT item.state FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id) <> 'restored'
    OR (SELECT customer_journal_entry_id IS NOT NULL
          OR provider_journal_entry_id IS NOT NULL
        FROM booking_supplier_payout_items AS item
        WHERE item.payout_id = payout.id)
  THEN RAISE EXCEPTION 'cancelled booking payout did not restore payable cleanly'; END IF;

  projection := read_booking_payout_beneficiaries(provider_org, provider_owner);
  IF jsonb_array_length(projection) <> 2
    OR projection::TEXT LIKE '%destination_ciphertext%'
    OR projection::TEXT LIKE '%xxxxxxxx%'
    OR projection::TEXT LIKE '%yyyyyyyy%'
  THEN RAISE EXCEPTION 'beneficiary read projection exposed encrypted destination data'; END IF;
END $$;

DO $$
BEGIN
  IF has_table_privilege(
      'service_role', 'booking_payout_beneficiaries', 'INSERT'
    )
    OR has_table_privilege(
      'service_role', 'booking_supplier_payout_items', 'UPDATE'
    )
    OR has_table_privilege(
      'authenticated', 'booking_payout_beneficiaries', 'SELECT'
    )
  THEN RAISE EXCEPTION 'booking payout tables expose direct access'; END IF;
END $$;
