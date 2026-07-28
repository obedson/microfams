DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009901';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009902';
  farmer CONSTANT UUID := '00000000-0000-4000-8000-000000009911';
  owner_user CONSTANT UUID := '00000000-0000-4000-8000-000000009912';
  property CONSTANT UUID := '00000000-0000-4000-8000-000000009921';
  result JSONB;
  replay JSONB;
  v_booking_id UUID;
  snapshot_id UUID;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (farmer, 'reservation-farmer@example.test', 'not-a-real-password', 'Reservation Farmer', 'farmer'),
    (owner_user, 'reservation-owner@example.test', 'not-a-real-password', 'Reservation Owner', 'owner');
  INSERT INTO organizations(id, name, slug, type, created_by) VALUES
    (customer_org, 'Reservation Customer', 'reservation-customer-test', 'cooperative', farmer),
    (provider_org, 'Reservation Provider', 'reservation-provider-test', 'farm_business', owner_user);
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at) VALUES
    (customer_org, farmer, 'member', 'active', NOW()),
    (provider_org, owner_user, 'owner', 'active', NOW());
  INSERT INTO properties(
    id, organization_id, owner_id, title, description, livestock_type, space_type,
    size, size_unit, city, lga, price_per_month, available_from, available_to, is_active
  ) VALUES (
    property, provider_org, owner_user, 'Atomic Reservation Property', 'Schema contract property',
    'poultry', 'empty_land', 100, 'm2', 'Abuja', 'AMAC', 1234.56,
    CURRENT_DATE, CURRENT_DATE + 365, TRUE
  );

  result := create_booking_reservation(customer_org, farmer, property,
    CURRENT_DATE + 10, CURRENT_DATE + 40, 'Initial reservation',
    'booking-reservation-schema-1', '00000000-0000-4000-8000-000000009931');
  v_booking_id := (result->'booking'->>'id')::UUID;
  snapshot_id := (result->'price_snapshot'->>'id')::UUID;
  IF (result->>'idempotency_replay')::BOOLEAN
    OR (result->'price_snapshot'->>'monthly_rate_minor')::BIGINT <> 123456
    OR (result->'price_snapshot'->>'duration_days')::INTEGER <> 30
    OR (result->'price_snapshot'->>'billed_months')::INTEGER <> 1
    OR (result->'price_snapshot'->>'total_minor')::BIGINT <> 123456
    OR (result->'booking'->>'total_amount')::NUMERIC <> 1234.56
    OR (result->'booking'->>'organization_id')::UUID <> customer_org
    OR (result->'booking'->>'provider_organization_id')::UUID <> provider_org
    OR result->'hold'->>'state' <> 'active'
    OR (result->'hold'->>'held_until')::TIMESTAMPTZ < NOW() + INTERVAL '47 hours'
  THEN RAISE EXCEPTION 'atomic reservation result is invalid: %', result; END IF;

  replay := create_booking_reservation(customer_org, farmer, property,
    CURRENT_DATE + 10, CURRENT_DATE + 40, 'Initial reservation',
    'booking-reservation-schema-1', '00000000-0000-4000-8000-000000009932');
  IF NOT (replay->>'idempotency_replay')::BOOLEAN
    OR replay->'booking'->>'id' <> v_booking_id::TEXT
    OR (SELECT count(*) FROM bookings WHERE id = v_booking_id) <> 1
  THEN RAISE EXCEPTION 'reservation replay was not idempotent'; END IF;

  BEGIN
    PERFORM create_booking_reservation(customer_org, farmer, property,
      CURRENT_DATE + 11, CURRENT_DATE + 41, 'Changed replay',
      'booking-reservation-schema-1', '00000000-0000-4000-8000-000000009933');
    RAISE EXCEPTION 'changed idempotent replay unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%IDEMPOTENCY_REPLAY_CONFLICT%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM create_booking_reservation(customer_org, farmer, property,
      CURRENT_DATE + 20, CURRENT_DATE + 50, NULL,
      'booking-reservation-overlap', '00000000-0000-4000-8000-000000009934');
    RAISE EXCEPTION 'overlapping reservation unexpectedly succeeded';
  EXCEPTION WHEN exclusion_violation THEN NULL;
  END;

  BEGIN
    UPDATE booking_price_snapshots SET total_minor = total_minor + 1 WHERE id = snapshot_id;
    RAISE EXCEPTION 'price snapshot mutation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%immutable%' THEN RAISE; END IF;
  END;

  UPDATE bookings SET payment_status = 'paid', status = 'confirmed' WHERE id = v_booking_id;
  IF (SELECT state FROM booking_reservation_holds WHERE booking_id = v_booking_id) <> 'converted' THEN
    RAISE EXCEPTION 'paid reservation hold was not converted';
  END IF;

  IF (SELECT count(*) FROM organization_audit_log
      WHERE resource_id = v_booking_id::TEXT AND action IN ('booking.reservation.created', 'booking.reservation.received')) <> 2
  THEN RAISE EXCEPTION 'reservation audit evidence is incomplete'; END IF;

  IF has_function_privilege('anon', 'create_booking_reservation(uuid,uuid,uuid,date,date,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'create_booking_reservation(uuid,uuid,uuid,date,date,text,text,uuid)', 'EXECUTE')
  THEN RAISE EXCEPTION 'reservation command is exposed to public API roles'; END IF;
END $$;
