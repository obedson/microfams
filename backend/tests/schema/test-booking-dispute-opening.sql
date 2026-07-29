DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009701';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009702';
  customer_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009711';
  provider_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009712';
  property_key CONSTANT UUID := '00000000-0000-4000-8000-000000009721';
  booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000009731';
  correlation CONSTANT UUID := '00000000-0000-4000-8000-000000009741';
  payment payments;
  contract booking_settlement_contracts;
  opened JSONB;
  replay JSONB;
  evidence JSONB;
  timeline JSONB;
  dispute_key UUID;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (customer_owner, 'dispute-customer@example.test', 'not-a-real-password', 'Dispute Customer', 'owner'),
    (provider_owner, 'dispute-provider@example.test', 'not-a-real-password', 'Dispute Provider', 'owner');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Dispute Customer Org', 'dispute-customer-test', 'cooperative', customer_owner),
    (provider_org, 'Dispute Provider Org', 'dispute-provider-test', 'farm_business', provider_owner);
  INSERT INTO organization_memberships(
    organization_id, user_id, role, status, joined_at
  ) VALUES
    (customer_org, customer_owner, 'owner', 'active', NOW()),
    (provider_org, provider_owner, 'owner', 'active', NOW());
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status) VALUES
    (customer_org, 'Dispute customer period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (provider_org, 'Dispute provider period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open');

  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property_key, provider_org, provider_owner, 'Dispute Property',
    'Property used to verify contested escrow freezing', 'poultry', 'empty_land',
    100, 'm2', 'Abuja', 'AMAC', 1000,
    CURRENT_DATE - 365, CURRENT_DATE + 365, TRUE
  );
  INSERT INTO bookings(
    id, organization_id, provider_organization_id, property_id, farmer_id,
    start_date, end_date, total_amount, status, payment_status
  ) VALUES (
    booking_key, customer_org, provider_org, property_key, customer_owner,
    CURRENT_DATE + 1, CURRENT_DATE + 31, 1000, 'pending', 'pending'
  );

  payment := create_payment_intent(
    customer_org, 'booking', booking_key, customer_owner, 'PAY-booking-dispute-001',
    'booking-dispute-payment-key', 'deterministic', 'deterministic', 'NGN', 100000,
    correlation, customer_owner
  );
  payment := mark_payment_initialized(
    payment.id, repeat('d', 64), 'PAY-booking-dispute-001', 'processing', NULL
  );
  payment := succeed_inbound_payment(
    payment.id, 'PAY-booking-dispute-001', 100000, 'NGN'
  );
  UPDATE bookings SET payment_status = 'paid' WHERE id = booking_key;

  opened := open_booking_dispute(
    booking_key, customer_org, customer_owner, 'unsafe_facilities',
    'The facilities were unsafe and materially unusable at arrival.',
    'refund', 40000, 'booking-dispute-open-001', correlation
  );
  dispute_key := (opened->>'dispute_id')::UUID;
  replay := open_booking_dispute(
    booking_key, customer_org, customer_owner, 'unsafe_facilities',
    'The facilities were unsafe and materially unusable at arrival.',
    'refund', 40000, 'booking-dispute-open-001', correlation
  );
  SELECT * INTO contract FROM booking_settlement_contracts WHERE booking_id = booking_key;

  IF contract.state <> 'disputed'
    OR (opened->>'contested_amount_minor')::BIGINT <> 40000
    OR NOT (replay->>'idempotency_replay')::BOOLEAN
    OR (SELECT count(*) FROM booking_settlement_allocations
      WHERE settlement_contract_id = contract.id AND allocation_type = 'contested'
        AND state = 'reserved' AND amount_minor = 40000
        AND source_type = 'booking_dispute' AND source_id = dispute_key) <> 1
    OR (SELECT count(*) FROM booking_settlement_holds
      WHERE settlement_contract_id = contract.id AND hold_type = 'dispute'
        AND state = 'active' AND amount_minor = 40000
        AND source_id = dispute_key::TEXT) <> 1
  THEN RAISE EXCEPTION 'booking dispute did not atomically freeze the contested amount'; END IF;

  BEGIN
    PERFORM open_booking_dispute(
      booking_key, customer_org, customer_owner, 'unsafe_facilities',
      'A changed replay must not be accepted for the same idempotency key.',
      'refund', 30000, 'booking-dispute-open-001', correlation
    );
    RAISE EXCEPTION 'changed dispute idempotency replay unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%IDEMPOTENCY_REPLAY_CONFLICT%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM open_booking_dispute(
      booking_key, customer_org, customer_owner, 'duplicate_charge',
      'The requested disputed amount exceeds the remaining funded balance.',
      'refund', 60001, 'booking-dispute-open-002', correlation
    );
    RAISE EXCEPTION 'over-contested booking dispute unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_DISPUTE_AMOUNT_EXCEEDS_AVAILABLE%' THEN RAISE; END IF;
  END;

  evidence := add_booking_dispute_evidence(
    dispute_key, provider_org, provider_owner, 'statement',
    'Provider statement supplied for the tenant-safe dispute record.',
    NULL, NULL, NULL, 'not_applicable', 'both', NULL,
    'booking-evidence-add-001', correlation
  );
  timeline := read_booking_dispute_timeline(
    booking_key, provider_org, provider_owner
  );
  IF evidence->>'evidence_id' IS NULL
    OR jsonb_array_length(timeline->'disputes') <> 1
    OR jsonb_array_length(timeline->'disputes'->0->'evidence') <> 1
    OR jsonb_array_length(timeline->'disputes'->0->'events') <> 2
    OR timeline::TEXT LIKE '%storage_object_key%'
  THEN RAISE EXCEPTION 'booking dispute evidence or sanitized timeline is invalid'; END IF;

  BEGIN
    UPDATE booking_dispute_evidence SET body = 'tampered' WHERE dispute_id = dispute_key;
    RAISE EXCEPTION 'append-only dispute evidence was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
  END;
END $$;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_disputes', 'INSERT')
    OR has_table_privilege('service_role', 'booking_dispute_evidence', 'UPDATE')
    OR has_table_privilege('service_role', 'booking_dispute_events', 'DELETE')
    OR has_table_privilege('authenticated', 'booking_disputes', 'SELECT')
  THEN RAISE EXCEPTION 'booking dispute tables expose direct access'; END IF;
  IF has_function_privilege(
      'authenticated',
      'open_booking_dispute(uuid,uuid,uuid,text,text,text,bigint,text,uuid)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'add_booking_dispute_evidence(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid,text,uuid)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'read_booking_dispute_timeline(uuid,uuid,uuid)',
      'EXECUTE'
    )
  THEN RAISE EXCEPTION 'booking dispute commands are exposed to authenticated callers'; END IF;
END $$;
