-- BR-01..BR-12 database integration and end-to-end lifecycle tests.
DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  farmer_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  owner_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  checker_id CONSTANT UUID := '00000000-0000-4000-8000-000000000103';
  property_id UUID;
  unpaid_booking UUID;
  paid_booking UUID;
  started_booking UUID;
  payment payments;
  cancellation JSONB;
  replay JSONB;
  approval JSONB;
  decision JSONB;
  refund payment_refunds;
BEGIN
  SELECT id INTO property_id FROM properties WHERE organization_id = provider_org LIMIT 1;
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on)
  VALUES (customer_org, 'Booking refund lifecycle', CURRENT_DATE - 365, CURRENT_DATE + 365)
  ON CONFLICT (organization_id, starts_on, ends_on) DO UPDATE
  SET status = 'open', closed_at = NULL, closed_by = NULL;
  SELECT id INTO unpaid_booking FROM bookings
    WHERE organization_id = customer_org AND payment_status = 'pending' LIMIT 1;

  cancellation := cancel_booking_with_refund(
    unpaid_booking, customer_org, farmer_id, 'No longer need this booking',
    'br-unpaid-cancel-001', '00000000-0000-4000-8000-000000009201'
  );
  replay := cancel_booking_with_refund(
    unpaid_booking, customer_org, farmer_id, 'No longer need this booking',
    'br-unpaid-cancel-001', '00000000-0000-4000-8000-000000009202'
  );
  IF cancellation->>'outcome' <> 'refund_not_required'
    OR replay->>'id' <> cancellation->>'id'
    OR replay->>'idempotency_replay' <> 'true'
    OR (SELECT status FROM bookings WHERE id = unpaid_booking) <> 'cancelled'
  THEN RAISE EXCEPTION 'unpaid cancellation or exact replay failed'; END IF;

  BEGIN
    PERFORM cancel_booking_with_refund(
      unpaid_booking, customer_org, farmer_id, 'Changed replay payload',
      'br-unpaid-cancel-001', '00000000-0000-4000-8000-000000009203'
    );
    RAISE EXCEPTION 'changed cancellation replay was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'changed cancellation replay was accepted' THEN RAISE; END IF;
  END;

  INSERT INTO bookings(
    property_id, farmer_id, organization_id, provider_organization_id,
    start_date, end_date, total_amount, status, payment_status, payment_reference
  ) VALUES (
    property_id, farmer_id, customer_org, provider_org,
    CURRENT_DATE + 10, CURRENT_DATE + 20, 1200, 'confirmed', 'paid', 'PAY-br-auto-001'
  ) RETURNING id INTO paid_booking;

  payment := create_payment_intent(
    customer_org, 'booking', paid_booking, farmer_id, 'PAY-br-auto-001',
    'br-auto-payment-001', 'deterministic', 'deterministic', 'NGN', 120000,
    '00000000-0000-4000-8000-000000009204', farmer_id
  );
  payment := mark_payment_initialized(payment.id, repeat('e', 64), 'PAY-br-auto-provider',
    'requires_action', NOW() + INTERVAL '1 hour');
  payment := succeed_inbound_payment(payment.id, 'PAY-br-auto-provider', 120000, 'NGN');

  cancellation := cancel_booking_with_refund(
    paid_booking, customer_org, farmer_id, 'Cancel before farm access begins',
    'br-paid-cancel-001', '00000000-0000-4000-8000-000000009205'
  );
  IF cancellation->>'outcome' <> 'refund_created'
    OR (cancellation->>'refund_amount_minor')::BIGINT <> 120000
    OR cancellation->>'policy_version' <> 'BR-2026-07-28'
  THEN RAISE EXCEPTION 'automatic pre-start refund obligation failed'; END IF;

  SELECT * INTO refund FROM payment_refunds WHERE id = (cancellation->>'refund_id')::UUID;
  refund := apply_payment_refund_result(refund.id, 'DET-br-auto-refund', 'processing', NULL, NULL);
  PERFORM sync_booking_cancellation_refund(refund.id);
  IF (SELECT outcome FROM booking_cancellations WHERE booking_id = paid_booking) <> 'refund_processing'
  THEN RAISE EXCEPTION 'processing refund was not synchronized'; END IF;
  refund := apply_payment_refund_result(refund.id, 'DET-br-auto-refund', 'succeeded', NULL, NULL);
  PERFORM sync_booking_cancellation_refund(refund.id);
  IF (SELECT outcome FROM booking_cancellations WHERE booking_id = paid_booking) <> 'refund_succeeded'
    OR (SELECT state FROM payments WHERE id = payment.id) <> 'refunded'
    OR NOT EXISTS (
      SELECT 1 FROM journal_lines WHERE journal_entry_id = refund.journal_entry_id
      GROUP BY journal_entry_id
      HAVING sum(CASE WHEN side = 'debit' THEN amount_minor ELSE -amount_minor END) = 0
    )
  THEN RAISE EXCEPTION 'confirmed refund did not synchronize and post a balanced journal'; END IF;

  INSERT INTO bookings(
    property_id, farmer_id, organization_id, provider_organization_id,
    start_date, end_date, total_amount, status, payment_status, payment_reference
  ) VALUES (
    property_id, farmer_id, customer_org, provider_org,
    CURRENT_DATE - 1, CURRENT_DATE + 5, 800, 'confirmed', 'paid', 'PAY-br-manual-001'
  ) RETURNING id INTO started_booking;
  payment := create_payment_intent(
    customer_org, 'booking', started_booking, farmer_id, 'PAY-br-manual-001',
    'br-manual-payment-001', 'deterministic', 'deterministic', 'NGN', 80000,
    '00000000-0000-4000-8000-000000009206', farmer_id
  );
  payment := mark_payment_initialized(payment.id, repeat('f', 64), 'PAY-br-manual-provider',
    'requires_action', NOW() + INTERVAL '1 hour');
  payment := succeed_inbound_payment(payment.id, 'PAY-br-manual-provider', 80000, 'NGN');
  cancellation := cancel_booking_with_refund(
    started_booking, provider_org, owner_id, 'Access has started and needs review',
    'br-started-cancel-001', '00000000-0000-4000-8000-000000009207'
  );
  IF cancellation->>'outcome' <> 'manual_review'
    OR cancellation->>'manual_review_reason' <> 'booking_started'
  THEN RAISE EXCEPTION 'post-start cancellation bypassed manual review'; END IF;

  UPDATE organization_memberships SET permissions = permissions || ARRAY['financial.refunds.approve']
  WHERE organization_id = customer_org AND user_id = checker_id;
  IF NOT FOUND THEN
    INSERT INTO organization_memberships(organization_id, user_id, role, permissions, status, joined_at)
    VALUES (customer_org, checker_id, 'finance_manager', ARRAY['financial.refunds.approve'], 'active', NOW());
  END IF;
  approval := propose_booking_refund(
    (cancellation->>'id')::UUID, customer_org, farmer_id, 50000,
    'Approved unused service portion', 'br-manual-proposal-001'
  );
  BEGIN
    PERFORM decide_booking_refund(
      (approval->>'id')::UUID, customer_org, farmer_id, TRUE,
      'Self approval should fail', 'br-manual-decision-self-001'
    );
    RAISE EXCEPTION 'maker approved own refund';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'maker approved own refund' THEN RAISE; END IF;
  END;
  decision := decide_booking_refund(
    (approval->>'id')::UUID, customer_org, checker_id, TRUE,
    'Independent checker approved partial refund', 'br-manual-decision-001'
  );
  IF decision->>'state' <> 'approved'
    OR (SELECT outcome FROM booking_cancellations WHERE booking_id = started_booking) <> 'refund_created'
    OR (SELECT amount_minor FROM payment_refunds WHERE id = (decision->>'refund_id')::UUID) <> 50000
  THEN RAISE EXCEPTION 'maker-checker refund approval failed'; END IF;
  decision := decide_booking_refund(
    (approval->>'id')::UUID, customer_org, checker_id, TRUE,
    'Independent checker approved partial refund', 'br-manual-decision-001'
  );
  IF decision->>'idempotency_replay' <> 'true' THEN
    RAISE EXCEPTION 'refund decision exact replay was not idempotent'; END IF;
  BEGIN
    PERFORM decide_booking_refund(
      (approval->>'id')::UUID, customer_org, checker_id, FALSE,
      'Changed decision replay', 'br-manual-decision-001'
    );
    RAISE EXCEPTION 'changed refund decision replay was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'changed refund decision replay was accepted' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM cancel_booking_with_refund(
      started_booking, checker_id, checker_id, 'Cross-tenant attempt',
      'br-cross-tenant-001', '00000000-0000-4000-8000-000000009208'
    );
    RAISE EXCEPTION 'cross-tenant cancellation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant cancellation was accepted' THEN RAISE; END IF;
  END;
END $$;

SET ROLE authenticated;
DO $$ BEGIN
  BEGIN
    PERFORM cancel_booking_with_refund(
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'Direct call denied',
      'br-direct-call-001', gen_random_uuid()
    );
    RAISE EXCEPTION 'authenticated role executed protected cancellation function';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
