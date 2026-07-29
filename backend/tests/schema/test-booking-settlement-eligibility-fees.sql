DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009601';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009602';
  platform_org CONSTANT UUID := '00000000-0000-4000-8000-000000009603';
  maker CONSTANT UUID := '00000000-0000-4000-8000-000000009611';
  checker CONSTANT UUID := '00000000-0000-4000-8000-000000009612';
  provider_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009613';
  platform_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009614';
  property_key CONSTANT UUID := '00000000-0000-4000-8000-000000009621';
  booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000009631';
  correlation CONSTANT UUID := '00000000-0000-4000-8000-000000009641';
  proposed JSONB;
  approval UUID;
  payment payments;
  contract booking_settlement_contracts;
  result JSONB;
  replay JSONB;
BEGIN
  IF calculate_booking_fee_minor(10050, 0, 100, 0, NULL) <> 101
    OR calculate_booking_fee_minor(10049, 0, 100, 0, NULL) <> 100
    OR calculate_booking_fee_minor(300, 500, 0, 500, 1000) <> 300
  THEN RAISE EXCEPTION 'booking fee integer rounding or cap is invalid'; END IF;

  INSERT INTO users(id, email, password, name, role) VALUES
    (maker, 'settlement-maker@example.test', 'not-a-real-password', 'Settlement Maker', 'owner'),
    (checker, 'settlement-checker@example.test', 'not-a-real-password', 'Settlement Checker', 'owner'),
    (provider_owner, 'settlement-provider-owner@example.test', 'not-a-real-password', 'Provider Owner', 'owner'),
    (platform_owner, 'settlement-platform-owner@example.test', 'not-a-real-password', 'Platform Owner', 'owner');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Eligibility Customer', 'eligibility-customer-test', 'cooperative', maker),
    (provider_org, 'Eligibility Provider', 'eligibility-provider-test', 'farm_business', provider_owner),
    (platform_org, 'Eligibility Platform', 'eligibility-platform-test', 'agribusiness', platform_owner);
  INSERT INTO organization_memberships(
    organization_id, user_id, role, status, joined_at
  ) VALUES
    (customer_org, maker, 'owner', 'active', NOW()),
    (customer_org, checker, 'owner', 'active', NOW()),
    (provider_org, provider_owner, 'owner', 'active', NOW()),
    (platform_org, platform_owner, 'owner', 'active', NOW());
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status) VALUES
    (customer_org, 'Eligibility customer period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (provider_org, 'Eligibility provider period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (platform_org, 'Eligibility platform period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open');

  proposed := propose_booking_settlement_rule(
    customer_org, maker, 2, 0, NOW() - INTERVAL '5 minutes',
    'Enable immediate settlement in the automated eligibility test.',
    'bs03-rule-proposal-001'
  );
  approval := (proposed->>'approval_id')::UUID;
  BEGIN
    PERFORM decide_booking_financial_rule(
      approval, customer_org, maker, TRUE, 'Maker must not approve the proposed rule.',
      'bs03-maker-decision-001'
    );
    RAISE EXCEPTION 'booking rule maker-checker separation was bypassed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MAKER_CHECKER_REQUIRED%' THEN RAISE; END IF;
  END;
  PERFORM decide_booking_financial_rule(
    approval, customer_org, checker, TRUE,
    'Independent approval for the immediate settlement test.', 'bs03-decision-001'
  );
  IF NOT (
    decide_booking_financial_rule(
      approval, customer_org, checker, TRUE,
      'Independent approval for the immediate settlement test.', 'bs03-decision-001'
    )->>'idempotency_replay'
  )::BOOLEAN THEN RAISE EXCEPTION 'booking rule decision replay is not idempotent'; END IF;

  proposed := propose_booking_fee_rule(
    customer_org, maker, 2, 'NGN', 'supplier', platform_org,
    100, 1000, 500, 15000, '{"tax_code":"TEST-NONE"}'::JSONB,
    NOW() - INTERVAL '5 minutes',
    'Apply the approved supplier-funded platform fee test rule.',
    'bs04-rule-proposal-001'
  );
  approval := (proposed->>'approval_id')::UUID;
  PERFORM decide_booking_financial_rule(
    approval, customer_org, checker, TRUE,
    'Independent approval for the platform fee test rule.', 'bs04-decision-001'
  );

  BEGIN
    PERFORM propose_booking_fee_rule(
      customer_org, maker, 3, 'NGN', 'customer', platform_org,
      100, 0, 0, 100, '{}'::JSONB, NOW(),
      'Customer fee cannot be added after the captured booking price.',
      'bs04-customer-fee-001'
    );
    RAISE EXCEPTION 'post-capture customer fee rule unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_CUSTOMER_FEE_REQUIRES_PREPAYMENT%' THEN RAISE; END IF;
  END;

  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property_key, provider_org, provider_owner, 'Eligibility Property',
    'Completed booking settlement property', 'poultry', 'empty_land',
    100, 'm2', 'Abuja', 'AMAC', 1000,
    CURRENT_DATE - 365, CURRENT_DATE + 365, TRUE
  );
  INSERT INTO bookings(
    id, organization_id, provider_organization_id, property_id, farmer_id,
    start_date, end_date, total_amount, status, payment_status
  ) VALUES (
    booking_key, customer_org, provider_org, property_key, maker,
    CURRENT_DATE - 10, CURRENT_DATE - 1, 1000, 'pending', 'pending'
  );

  payment := create_payment_intent(
    customer_org, 'booking', booking_key, maker, 'PAY-booking-release-001',
    'booking-release-payment-key', 'deterministic', 'deterministic', 'NGN', 100000,
    correlation, maker
  );
  payment := mark_payment_initialized(
    payment.id, repeat('c', 64), 'PAY-booking-release-001', 'processing', NULL
  );
  payment := succeed_inbound_payment(
    payment.id, 'PAY-booking-release-001', 100000, 'NGN'
  );
  UPDATE bookings SET payment_status = 'paid' WHERE id = booking_key;
  PERFORM transition_booking_state(
    booking_key, provider_org, provider_owner, 'confirmed',
    'booking-release-confirm-001', correlation
  );
  PERFORM transition_booking_state(
    booking_key, provider_org, provider_owner, 'completed',
    'booking-release-complete-001', correlation
  );

  SELECT * INTO contract FROM booking_settlement_contracts WHERE booking_id = booking_key;
  IF contract.state <> 'completed_pending_window'
    OR contract.completed_at IS NULL
    OR contract.dispute_deadline_at <> contract.completed_at
    OR contract.settlement_rule_id IS NULL
    OR contract.fee_rule_id IS NULL
    OR contract.eligibility_snapshot->'fee_rule'->>'payer' <> 'supplier'
  THEN RAISE EXCEPTION 'booking completion settlement snapshot is invalid'; END IF;

  result := release_booking_settlement(
    booking_key, customer_org, maker, 'booking-release-command-001', correlation
  );
  replay := release_booking_settlement(
    booking_key, customer_org, maker, 'booking-release-command-001', correlation
  );
  SELECT * INTO contract FROM booking_settlement_contracts WHERE booking_id = booking_key;

  IF contract.state <> 'settled'
    OR contract.supplier_amount_minor <> 89900
    OR contract.platform_fee_amount_minor <> 10100
    OR contract.customer_release_journal_entry_id IS NULL
    OR contract.provider_recognition_journal_entry_id IS NULL
    OR contract.platform_recognition_journal_entry_id IS NULL
    OR NOT (replay->>'idempotency_replay')::BOOLEAN
    OR wallet_account_balance_minor(contract.escrow_account_id) <> 0
  THEN RAISE EXCEPTION 'booking settlement release result is invalid: %', result; END IF;

  IF (SELECT count(*) FROM booking_settlement_allocations
      WHERE settlement_contract_id = contract.id AND state = 'final'
        AND allocation_type IN ('supplier', 'platform_fee')) <> 2
    OR (SELECT sum(amount_minor) FROM booking_settlement_allocations
      WHERE settlement_contract_id = contract.id AND state = 'final'
        AND allocation_type IN ('supplier', 'platform_fee')) <> 100000
    OR (SELECT count(DISTINCT correlation_id) FROM booking_settlement_posting_links
      WHERE settlement_contract_id = contract.id) <> 1
    OR (SELECT count(DISTINCT journal_entry_id) FROM booking_settlement_posting_links
      WHERE settlement_contract_id = contract.id) <> 3
  THEN RAISE EXCEPTION 'booking settlement allocation or cross-tenant posting links are invalid'; END IF;

  IF EXISTS (
    SELECT entry.id
    FROM journal_entries entry
    JOIN journal_lines line ON line.journal_entry_id = entry.id
    WHERE entry.id IN (
      contract.customer_release_journal_entry_id,
      contract.provider_recognition_journal_entry_id,
      contract.platform_recognition_journal_entry_id
    )
    GROUP BY entry.id
    HAVING sum(CASE WHEN line.side = 'debit' THEN line.amount_minor ELSE -line.amount_minor END) <> 0
  ) OR (
    SELECT count(*) FROM journal_entries
    WHERE id IN (
      contract.customer_release_journal_entry_id,
      contract.provider_recognition_journal_entry_id,
      contract.platform_recognition_journal_entry_id
    ) AND correlation_id = correlation
  ) <> 3
  THEN RAISE EXCEPTION 'booking release journals are not balanced and correlated'; END IF;

  IF read_booking_settlement_summary(booking_key, customer_org, maker)->>'state' <> 'settled'
  THEN RAISE EXCEPTION 'booking settlement read model is invalid'; END IF;
  IF jsonb_array_length(
      read_booking_financial_rules(customer_org, checker)->'settlement_rules'
    ) <> 2
    OR jsonb_array_length(
      read_booking_financial_rules(customer_org, checker)->'fee_rules'
    ) <> 2
    OR jsonb_array_length(
      read_booking_financial_rules(customer_org, checker)->'pending_approvals'
    ) <> 0
  THEN RAISE EXCEPTION 'booking financial rule read model is invalid'; END IF;
END $$;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_settlement_rules', 'INSERT')
    OR has_table_privilege('service_role', 'booking_fee_rules', 'UPDATE')
    OR has_table_privilege('service_role', 'booking_settlement_holds', 'DELETE')
    OR has_table_privilege('authenticated', 'booking_settlement_posting_links', 'SELECT')
  THEN RAISE EXCEPTION 'booking settlement eligibility tables expose direct mutation or reads'; END IF;
  IF has_function_privilege(
      'authenticated',
      'release_booking_settlement(uuid,uuid,uuid,text,uuid)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'read_booking_financial_rules(uuid,uuid)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'decide_booking_financial_rule(uuid,uuid,uuid,boolean,text,text)',
      'EXECUTE'
    )
  THEN RAISE EXCEPTION 'booking settlement release is exposed to authenticated callers'; END IF;
END $$;
