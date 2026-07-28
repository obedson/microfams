DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000008901';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000008902';
  outsider_org CONSTANT UUID := '00000000-0000-4000-8000-000000008903';
  farmer CONSTANT UUID := '00000000-0000-4000-8000-000000008911';
  owner_user CONSTANT UUID := '00000000-0000-4000-8000-000000008912';
  outsider CONSTANT UUID := '00000000-0000-4000-8000-000000008913';
  property_key CONSTANT UUID := '00000000-0000-4000-8000-000000008921';
  booking_key CONSTANT UUID := '00000000-0000-4000-8000-000000008931';
  unpaid_booking CONSTANT UUID := '00000000-0000-4000-8000-000000008932';
  future_booking CONSTANT UUID := '00000000-0000-4000-8000-000000008933';
  result JSONB;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (farmer, 'lifecycle-farmer@example.test', 'not-a-real-password', 'Lifecycle Farmer', 'farmer'),
    (owner_user, 'lifecycle-owner@example.test', 'not-a-real-password', 'Lifecycle Owner', 'owner'),
    (outsider, 'lifecycle-outsider@example.test', 'not-a-real-password', 'Lifecycle Outsider', 'owner');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Lifecycle Customer', 'lifecycle-customer-test', 'cooperative', farmer),
    (provider_org, 'Lifecycle Provider', 'lifecycle-provider-test', 'farm_business', owner_user),
    (outsider_org, 'Lifecycle Outsider', 'lifecycle-outsider-test', 'farm_business', outsider);
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at) VALUES
    (customer_org, farmer, 'member', 'active', NOW()),
    (provider_org, owner_user, 'owner', 'active', NOW()),
    (outsider_org, outsider, 'owner', 'active', NOW());
  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property_key, provider_org, owner_user, 'Lifecycle Property', 'Lifecycle contract property',
    'poultry', 'empty_land', 100, 'm2', 'Abuja', 'AMAC', 1000,
    CURRENT_DATE - 30, CURRENT_DATE + 365, TRUE
  );
  INSERT INTO bookings(
    id, organization_id, provider_organization_id, property_id, farmer_id,
    start_date, end_date, total_amount, status, payment_status
  ) VALUES
    (booking_key, customer_org, provider_org, property_key, farmer,
      CURRENT_DATE - 2, CURRENT_DATE - 1, 1000, 'pending', 'paid'),
    (unpaid_booking, customer_org, provider_org, property_key, farmer,
      CURRENT_DATE + 20, CURRENT_DATE + 30, 1000, 'pending', 'pending'),
    (future_booking, customer_org, provider_org, property_key, farmer,
      CURRENT_DATE + 40, CURRENT_DATE + 50, 1000, 'confirmed', 'paid');

  BEGIN
    PERFORM transition_booking_state(booking_key, outsider_org, outsider, 'confirmed',
      'booking-lifecycle-wrong-tenant', '00000000-0000-4000-8000-000000008941');
    RAISE EXCEPTION 'cross-tenant transition unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_TRANSITION_NOT_AUTHORIZED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM transition_booking_state(unpaid_booking, provider_org, owner_user, 'confirmed',
      'booking-lifecycle-unpaid', '00000000-0000-4000-8000-000000008942');
    RAISE EXCEPTION 'unpaid confirmation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_PAYMENT_REQUIRED%' THEN RAISE; END IF;
  END;

  result := transition_booking_state(booking_key, provider_org, owner_user, 'confirmed',
    'booking-lifecycle-confirm', '00000000-0000-4000-8000-000000008943');
  IF result->'booking'->>'status' <> 'confirmed' OR (result->>'idempotency_replay')::BOOLEAN THEN
    RAISE EXCEPTION 'confirmation result is invalid: %', result;
  END IF;
  result := transition_booking_state(booking_key, provider_org, owner_user, 'confirmed',
    'booking-lifecycle-confirm', '00000000-0000-4000-8000-000000008944');
  IF NOT (result->>'idempotency_replay')::BOOLEAN
    OR (SELECT count(*) FROM booking_state_transitions WHERE booking_id = booking_key) <> 1
  THEN RAISE EXCEPTION 'confirmation replay was not idempotent'; END IF;
  BEGIN
    PERFORM transition_booking_state(booking_key, provider_org, owner_user, 'completed',
      'booking-lifecycle-confirm', '00000000-0000-4000-8000-000000008945');
    RAISE EXCEPTION 'changed replay unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%IDEMPOTENCY_REPLAY_CONFLICT%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM transition_booking_state(future_booking, provider_org, owner_user, 'completed',
      'booking-lifecycle-too-early', '00000000-0000-4000-8000-000000008946');
    RAISE EXCEPTION 'early completion unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_COMPLETION_TOO_EARLY%' THEN RAISE; END IF;
  END;

  result := transition_booking_state(booking_key, provider_org, owner_user, 'completed',
    'booking-lifecycle-complete', '00000000-0000-4000-8000-000000008947');
  IF result->'booking'->>'status' <> 'completed'
    OR (SELECT count(*) FROM booking_status_history WHERE booking_id = booking_key) <> 2
    OR (SELECT count(*) FROM organization_audit_log WHERE resource_id = booking_key::TEXT
      AND action IN ('booking.confirmed', 'booking.completed')) <> 4
  THEN RAISE EXCEPTION 'completion or audit evidence is incomplete'; END IF;

  IF has_function_privilege('anon', 'transition_booking_state(uuid,uuid,uuid,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'transition_booking_state(uuid,uuid,uuid,text,text,uuid)', 'EXECUTE')
  THEN RAISE EXCEPTION 'booking lifecycle command is exposed to public API roles'; END IF;
END $$;
