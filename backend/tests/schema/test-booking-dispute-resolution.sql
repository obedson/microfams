DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009801';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009802';
  approver_org CONSTANT UUID := '00000000-0000-4000-8000-000000009803';
  customer_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009811';
  provider_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009812';
  independent_approver CONSTANT UUID := '00000000-0000-4000-8000-000000009813';
  property_key CONSTANT UUID := '00000000-0000-4000-8000-000000009821';
  booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000009831';
  correlation CONSTANT UUID := '00000000-0000-4000-8000-000000009841';
  payment payments;
  contract booking_settlement_contracts;
  opened JSONB;
  transition_result JSONB;
  proposal JSONB;
  decision JSONB;
  replay JSONB;
  case_view JSONB;
  dispute_key UUID;
  proposal_key UUID;
  refund_key UUID;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (customer_owner, 'resolution-customer@example.test', 'not-a-real-password', 'Resolution Customer', 'owner'),
    (provider_owner, 'resolution-provider@example.test', 'not-a-real-password', 'Resolution Provider', 'owner'),
    (independent_approver, 'resolution-approver@example.test', 'not-a-real-password', 'Resolution Approver', 'admin');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Resolution Customer Org', 'resolution-customer-test', 'cooperative', customer_owner),
    (provider_org, 'Resolution Provider Org', 'resolution-provider-test', 'farm_business', provider_owner),
    (approver_org, 'Resolution Approval Org', 'resolution-approval-test', 'ngo', independent_approver);
  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, joined_at
  ) VALUES
    (customer_org, customer_owner, 'owner', ARRAY[]::TEXT[], 'active', NOW()),
    (provider_org, provider_owner, 'owner', ARRAY[]::TEXT[], 'active', NOW()),
    (approver_org, independent_approver, 'admin',
      ARRAY['booking.disputes.approve'], 'active', NOW());
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status) VALUES
    (customer_org, 'Resolution customer period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (provider_org, 'Resolution provider period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open'),
    (approver_org, 'Resolution approval period', CURRENT_DATE - 30, CURRENT_DATE + 30, 'open');
  INSERT INTO platform_administrator_assignments(
    user_id, granted_by, grant_reason_code
  ) VALUES (independent_approver, NULL, 'BS07_INDEPENDENT_APPROVER');
  INSERT INTO platform_administration_events(
    actor_id, action, target_user_id, reason_code, metadata
  ) VALUES (
    independent_approver, 'platform_admin.granted', independent_approver,
    'BS07_INDEPENDENT_APPROVER', '{"schema_test":true}'::JSONB
  );

  IF (SELECT response_period_days FROM booking_dispute_response_rules
      WHERE organization_id = customer_org AND status = 'active') <> 3
  THEN RAISE EXCEPTION 'default three-day response rule was not provisioned'; END IF;

  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property_key, provider_org, provider_owner, 'Resolution Property',
    'Property used to verify dispute resolution accounting', 'poultry', 'empty_land',
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
    customer_org, 'booking', booking_key, customer_owner, 'PAY-booking-resolution-001',
    'booking-resolution-payment-key', 'deterministic', 'deterministic', 'NGN', 100000,
    correlation, customer_owner
  );
  payment := mark_payment_initialized(
    payment.id, repeat('e', 64), 'PAY-booking-resolution-001', 'processing', NULL
  );
  payment := succeed_inbound_payment(
    payment.id, 'PAY-booking-resolution-001', 100000, 'NGN'
  );
  UPDATE bookings SET payment_status = 'paid' WHERE id = booking_key;

  opened := open_booking_dispute(
    booking_key, customer_org, customer_owner, 'unsafe_facilities',
    'The facilities were unsafe and materially unusable at arrival.',
    'refund', 40000, 'booking-resolution-open-001', correlation
  );
  dispute_key := (opened->>'dispute_id')::UUID;
  SELECT * INTO contract FROM booking_settlement_contracts WHERE booking_id = booking_key;
  IF (SELECT (rule_snapshot->>'response_rule_version')::INTEGER
      FROM booking_disputes WHERE id = dispute_key) <> 1
    OR (SELECT response_deadline_at FROM booking_disputes WHERE id = dispute_key)
      < NOW() + INTERVAL '71 hours'
    OR (SELECT count(*) FROM booking_dispute_notices WHERE dispute_id = dispute_key) <> 2
  THEN RAISE EXCEPTION 'response rule snapshot or opening notices are invalid'; END IF;

  transition_result := transition_booking_dispute(
    dispute_key, customer_org, customer_owner, 'evidence_collection',
    'The parties must submit the relevant evidence for review.',
    'booking-resolution-transition-001', correlation
  );
  transition_result := transition_booking_dispute(
    dispute_key, customer_org, customer_owner, 'under_review',
    'The evidence window is complete and the case is ready for review.',
    'booking-resolution-transition-002', correlation
  );
  IF (SELECT from_state FROM booking_dispute_events
      WHERE dispute_id = dispute_key AND to_state = 'under_review'
      ORDER BY occurred_at DESC LIMIT 1) <> 'evidence_collection'
  THEN RAISE EXCEPTION 'dispute transition did not audit the actual prior state'; END IF;

  proposal := propose_booking_dispute_resolution(
    dispute_key, customer_org, customer_owner,
    15000, 25000, 0, 0, 0,
    'Approve a partial customer refund and release the conserved balance.',
    ARRAY[]::UUID[], 'booking-resolution-proposal-001', correlation
  );
  proposal_key := (proposal->>'proposal_id')::UUID;
  IF (proposal->'accounting_preview'->>'balanced')::BOOLEAN IS NOT TRUE
    OR (SELECT sum(amount_minor) FROM booking_dispute_resolution_allocations
        WHERE proposal_id = proposal_key) <> 40000
  THEN RAISE EXCEPTION 'resolution proposal was not exactly conserved'; END IF;

  BEGIN
    PERFORM decide_booking_dispute_resolution_authorized(
      proposal_key, customer_org, customer_owner, TRUE,
      'The maker cannot approve their own resolution proposal.',
      'booking-resolution-maker-001', correlation
    );
    RAISE EXCEPTION 'maker unexpectedly approved a resolution';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT%'
      AND SQLERRM NOT LIKE '%MAKER_CHECKER_REQUIRED%'
    THEN RAISE; END IF;
  END;

  decision := decide_booking_dispute_resolution_authorized(
    proposal_key, approver_org, independent_approver, TRUE,
    'Independent review confirms the proposed split is fair and conserved.',
    'booking-resolution-decision-001', correlation
  );
  refund_key := (decision->>'refund_id')::UUID;
  replay := decide_booking_dispute_resolution_authorized(
    proposal_key, approver_org, independent_approver, TRUE,
    'Independent review confirms the proposed split is fair and conserved.',
    'booking-resolution-decision-001', correlation
  );
  IF decision->>'state' <> 'approved'
    OR decision->>'dispute_state' <> 'resolved_split'
    OR NOT (replay->>'idempotency_replay')::BOOLEAN
    OR (SELECT state FROM booking_dispute_resolution_proposals WHERE id = proposal_key) <> 'approved'
    OR (SELECT state FROM payment_refunds WHERE id = refund_key) <> 'created'
    OR (SELECT count(*) FROM booking_settlement_allocations
        WHERE settlement_contract_id = contract.id AND allocation_type = 'refund'
          AND state = 'reserved' AND amount_minor = 15000 AND source_id = refund_key) <> 1
    OR (SELECT COALESCE(sum(amount_minor), 0) FROM booking_settlement_allocations
        WHERE settlement_contract_id = contract.id AND allocation_type = 'supplier'
          AND state = 'final') <> 25000
    OR (SELECT count(*) FROM booking_settlement_allocations
        WHERE settlement_contract_id = contract.id AND allocation_type = 'contested'
          AND source_id = dispute_key AND state = 'reserved') <> 0
    OR (SELECT count(*) FROM booking_settlement_holds
        WHERE settlement_contract_id = contract.id AND hold_type = 'refund'
          AND state = 'active' AND amount_minor = 15000) <> 1
    OR (SELECT count(*) FROM booking_settlement_holds
        WHERE settlement_contract_id = contract.id AND hold_type = 'dispute'
          AND source_id = dispute_key::TEXT AND state = 'active') <> 0
  THEN RAISE EXCEPTION 'approved resolution did not atomically create its dispositions'; END IF;

  BEGIN
    PERFORM decide_booking_dispute_resolution_authorized(
      proposal_key, approver_org, independent_approver, FALSE,
      'A changed replay must not alter the recorded resolution decision.',
      'booking-resolution-decision-001', correlation
    );
    RAISE EXCEPTION 'changed decision replay unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_DISPUTE_DECISION_ALREADY_RECORDED%'
    THEN RAISE; END IF;
  END;

  case_view := read_booking_dispute_resolution_case(
    dispute_key, customer_org, customer_owner
  );
  IF jsonb_array_length(case_view->'proposals') <> 1
    OR jsonb_array_length(case_view->'recovery_commands') <> 0
    OR jsonb_array_length(case_view->'notices') < 3
  THEN RAISE EXCEPTION 'tenant-safe resolution case projection is incomplete'; END IF;

  BEGIN
    UPDATE booking_dispute_resolution_proposals
    SET reason = 'tampered' WHERE id = proposal_key;
    RAISE EXCEPTION 'resolution proposal was directly mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%dispute engine%' THEN RAISE; END IF;
  END;
END $$;

DO $$
BEGIN
  IF has_table_privilege('service_role', 'booking_dispute_resolution_proposals', 'INSERT')
    OR has_table_privilege('service_role', 'booking_dispute_resolution_allocations', 'UPDATE')
    OR has_table_privilege('authenticated', 'booking_dispute_notices', 'SELECT')
  THEN RAISE EXCEPTION 'dispute resolution tables expose direct mutation or tenant reads'; END IF;
  IF has_function_privilege(
      'authenticated', 'decide_booking_dispute_resolution_authorized(
        uuid,uuid,uuid,boolean,text,text,uuid)', 'EXECUTE'
    )
  THEN RAISE EXCEPTION 'resolution approval is exposed to authenticated callers'; END IF;
  IF to_regprocedure(
    'decide_booking_dispute_resolution_authorized(
      uuid,uuid,uuid,boolean,text,text,uuid)'
  ) IS NULL
  THEN RAISE EXCEPTION 'organization-scoped resolution approval is missing'; END IF;
END $$;
