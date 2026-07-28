DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009501';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009502';
  farmer CONSTANT UUID := '00000000-0000-4000-8000-000000009511';
  owner_user CONSTANT UUID := '00000000-0000-4000-8000-000000009512';
  property_key CONSTANT UUID := '00000000-0000-4000-8000-000000009521';
  booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000009531';
  reversal_booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000009532';
  payment payments;
  replay payments;
  refund payment_refunds;
  contract booking_settlement_contracts;
  reversal_contract booking_settlement_contracts;
  escrow_balance BIGINT;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (farmer, 'settlement-farmer@example.test', 'not-a-real-password', 'Settlement Farmer', 'farmer'),
    (owner_user, 'settlement-owner@example.test', 'not-a-real-password', 'Settlement Owner', 'owner');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Settlement Customer', 'settlement-customer-test', 'cooperative', farmer),
    (provider_org, 'Settlement Provider', 'settlement-provider-test', 'farm_business', owner_user);
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at) VALUES
    (customer_org, farmer, 'member', 'active', NOW()),
    (provider_org, owner_user, 'owner', 'active', NOW());
  INSERT INTO accounting_periods(
    organization_id, name, starts_on, ends_on, status
  ) VALUES
    (customer_org, 'Settlement test period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (provider_org, 'Settlement provider test period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open');
  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property_key, provider_org, owner_user, 'Settlement Property',
    'Booking settlement contract property', 'poultry', 'empty_land',
    100, 'm2', 'Abuja', 'AMAC', 1234.50,
    CURRENT_DATE - 30, CURRENT_DATE + 365, TRUE
  );
  INSERT INTO bookings(
    id, organization_id, provider_organization_id, property_id, farmer_id,
    start_date, end_date, total_amount, status, payment_status
  ) VALUES
    (
      booking_key, customer_org, provider_org, property_key, farmer,
      CURRENT_DATE + 10, CURRENT_DATE + 20, 1234.50, 'pending_payment', 'pending'
    ),
    (
      reversal_booking_key, customer_org, provider_org, property_key, farmer,
      CURRENT_DATE + 40, CURRENT_DATE + 50, 500, 'pending_payment', 'pending'
    );

  payment := create_payment_intent(
    customer_org, 'booking', booking_key, farmer, 'PAY-booking-escrow-001',
    'booking-escrow-payment-key', 'deterministic', 'deterministic', 'NGN', 123450,
    '00000000-0000-4000-8000-000000009541', farmer
  );
  payment := mark_payment_initialized(
    payment.id, repeat('a', 64), 'PAY-booking-escrow-001', 'processing', NULL
  );
  payment := succeed_inbound_payment(
    payment.id, 'PAY-booking-escrow-001', 123450, 'NGN'
  );
  replay := succeed_inbound_payment(
    payment.id, 'PAY-booking-escrow-001', 123450, 'NGN'
  );
  SELECT * INTO contract FROM booking_settlement_contracts
  WHERE booking_id = booking_key;

  IF contract.id IS NULL
    OR contract.payment_id <> payment.id
    OR contract.organization_id <> customer_org
    OR contract.provider_organization_id <> provider_org
    OR contract.gross_amount_minor <> 123450
    OR contract.currency <> 'NGN'
    OR contract.state <> 'funded'
    OR contract.policy_version <> 'BS-2026-07-28'
    OR replay.success_journal_entry_id <> payment.success_journal_entry_id
    OR (SELECT count(*) FROM booking_settlement_contracts WHERE booking_id = booking_key) <> 1
  THEN RAISE EXCEPTION 'booking settlement funding contract is invalid'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM financial_accounts
    WHERE id = contract.escrow_account_id
      AND organization_id = customer_org
      AND purpose = 'escrow_funds_held'
      AND owner_type = 'escrow_contract'
      AND owner_id = contract.id
      AND account_class = 'liability'
      AND normal_side = 'credit'
  ) THEN RAISE EXCEPTION 'booking escrow account mapping is invalid'; END IF;

  SELECT wallet_account_balance_minor(contract.escrow_account_id) INTO escrow_balance;
  IF escrow_balance <> 123450 THEN
    RAISE EXCEPTION 'booking escrow balance mismatch after funding: %', escrow_balance;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM journal_entries entry
    JOIN journal_lines line ON line.journal_entry_id = entry.id
    WHERE entry.id = contract.escrow_funding_journal_entry_id
    GROUP BY entry.id
    HAVING sum(CASE WHEN line.side = 'debit' THEN line.amount_minor ELSE -line.amount_minor END) = 0
      AND sum(line.amount_minor) FILTER (
        WHERE line.account_id = contract.escrow_account_id AND line.side = 'credit'
      ) = 123450
  ) THEN RAISE EXCEPTION 'booking escrow funding journal is not balanced'; END IF;
  IF (SELECT count(*) FROM organization_audit_log
      WHERE resource_id = contract.id::TEXT AND action = 'booking.settlement.funded') <> 2
  THEN RAISE EXCEPTION 'booking settlement tenant audit evidence is incomplete'; END IF;

  refund := create_payment_refund(
    payment.id, 'REF-booking-escrow-001', 'booking-escrow-refund-key', 23450,
    'booking_pre_start_cancellation', 'Approved booking refund', farmer, 'approval-bs-001'
  );
  refund := apply_payment_refund_result(
    refund.id, 'DET-booking-refund-001', 'processing', NULL, NULL
  );
  refund := apply_payment_refund_result(
    refund.id, 'DET-booking-refund-001', 'succeeded', NULL, NULL
  );
  SELECT * INTO contract FROM booking_settlement_contracts WHERE id = contract.id;
  SELECT wallet_account_balance_minor(contract.escrow_account_id) INTO escrow_balance;
  IF contract.state <> 'partially_refunded'
    OR escrow_balance <> 100000
    OR NOT EXISTS (
      SELECT 1 FROM booking_settlement_allocations
      WHERE settlement_contract_id = contract.id
        AND allocation_type = 'refund'
        AND state = 'final'
        AND amount_minor = 23450
        AND source_id = refund.id
    )
  THEN RAISE EXCEPTION 'booking escrow refund allocation is invalid'; END IF;

  payment := create_payment_intent(
    customer_org, 'booking', reversal_booking_key, farmer, 'PAY-booking-reversal-001',
    'booking-reversal-payment-key', 'deterministic', 'deterministic', 'NGN', 50000,
    '00000000-0000-4000-8000-000000009542', farmer
  );
  payment := mark_payment_initialized(
    payment.id, repeat('b', 64), 'PAY-booking-reversal-001', 'processing', NULL
  );
  payment := succeed_inbound_payment(
    payment.id, 'PAY-booking-reversal-001', 50000, 'NGN'
  );
  PERFORM reverse_inbound_payment(
    payment.id, 'booking-provider-reversal-001', 'REV-booking-escrow-001',
    50000, 'Provider reversed booking payment', NOW()
  );
  SELECT * INTO reversal_contract FROM booking_settlement_contracts
  WHERE booking_id = reversal_booking_key;
  IF reversal_contract.state <> 'reversed'
    OR wallet_account_balance_minor(reversal_contract.escrow_account_id) <> 0
    OR NOT EXISTS (
      SELECT 1 FROM booking_settlement_allocations
      WHERE settlement_contract_id = reversal_contract.id
        AND allocation_type = 'reversal'
        AND amount_minor = 50000
    )
  THEN RAISE EXCEPTION 'booking escrow reversal allocation is invalid'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM feature_flags
    WHERE key = 'booking.settlements.create'
      AND NOT default_enabled
      AND failure_mode = 'closed'
      AND risk = 'regulated'
  ) OR NOT EXISTS (
    SELECT 1 FROM feature_flags
    WHERE key = 'booking.settlements.service_existing'
      AND default_enabled
      AND failure_mode = 'open'
      AND risk = 'regulated'
  ) THEN RAISE EXCEPTION 'booking settlement acquisition/servicing flags are invalid'; END IF;

END $$;

SET ROLE service_role;
DO $$
BEGIN
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  BEGIN
    UPDATE booking_settlement_contracts SET state = 'eligible'
    WHERE booking_id = '00000000-0000-4000-8000-000000009531';
    RAISE EXCEPTION 'caller-controlled setting bypassed settlement mutation protection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'caller-controlled setting bypassed settlement mutation protection' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_settlement_contracts', 'INSERT')
    OR has_table_privilege('service_role', 'booking_settlement_contracts', 'UPDATE')
    OR has_table_privilege('service_role', 'booking_settlement_contracts', 'DELETE')
    OR has_table_privilege('service_role', 'booking_settlement_allocations', 'INSERT')
    OR has_table_privilege('service_role', 'booking_settlement_allocations', 'UPDATE')
    OR has_table_privilege('service_role', 'booking_settlement_allocations', 'DELETE')
  THEN RAISE EXCEPTION 'service_role can directly mutate booking settlement records'; END IF;
  IF has_table_privilege('anon', 'booking_settlement_contracts', 'SELECT')
    OR has_table_privilege('authenticated', 'booking_settlement_contracts', 'SELECT')
  THEN RAISE EXCEPTION 'booking settlement records are exposed to public API roles'; END IF;
END $$;
