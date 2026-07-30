-- BS-10B payout resource isolation and masked state projection.

DO $$
DECLARE
  customer_org CONSTANT UUID := '00000000-0000-4000-8000-000000009801';
  provider_org CONSTANT UUID := '00000000-0000-4000-8000-000000009802';
  customer_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009811';
  provider_owner CONSTANT UUID := '00000000-0000-4000-8000-000000009812';
  independent_actor CONSTANT UUID := '00000000-0000-4000-8000-000000009813';
  payout_reader CONSTANT UUID := '00000000-0000-4000-8000-000000009815';
  payout_id UUID;
  authorization_result JSONB;
  projection JSONB;
  decision booking_authorization_decisions;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES (
    payout_reader, 'booking-payout-reader@example.test', 'not-a-real-password',
    'Booking Payout Reader', 'admin'
  );
  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, joined_at
  ) VALUES (
    provider_org, payout_reader, 'viewer',
    ARRAY['booking.payouts.read'], 'active', NOW()
  );
  SELECT payout.id INTO payout_id
  FROM payouts AS payout
  WHERE payout.organization_id = provider_org
    AND payout.source_type = 'booking_settlement'
  ORDER BY payout.created_at
  LIMIT 1;
  IF payout_id IS NULL
  THEN RAISE EXCEPTION 'booking payout fixture is missing'; END IF;

  IF NOT authorize_booking_payout_resource(
    provider_org, provider_owner, 'booking.payouts.read',
    'booking_supplier_payout', payout_id
  ) THEN RAISE EXCEPTION 'authorized payout read was denied'; END IF;

  projection := read_booking_supplier_payout(
    payout_id, provider_org, provider_owner
  );
  IF projection->>'id' <> payout_id::TEXT
    OR projection->>'destination_masked' IS NULL
    OR projection::TEXT LIKE '%destination_ciphertext%'
    OR projection::TEXT LIKE '%0123456789%'
  THEN RAISE EXCEPTION 'payout state projection is missing or unsafe'; END IF;

  projection := read_booking_payout_beneficiaries(
    provider_org, payout_reader
  );
  IF jsonb_array_length(projection) < 1
  THEN RAISE EXCEPTION 'dedicated payout reader could not list beneficiaries'; END IF;

  authorization_result := evaluate_booking_authorization(
    customer_org, customer_owner, 'booking.payouts.read',
    'booking.payout.read', 'booking_supplier_payout', payout_id::TEXT,
    '00000000-0000-4000-8000-000000009816',
    'booking-payout-cross-tenant-read'
  );
  IF (authorization_result->>'allowed')::BOOLEAN
  THEN RAISE EXCEPTION 'cross-tenant payout audit was recorded as allowed'; END IF;
  SELECT * INTO decision
  FROM booking_authorization_decisions
  WHERE id = (authorization_result->>'decision_id')::UUID;
  IF decision.outcome <> 'denied'
    OR decision.resource_reference IS NOT NULL
    OR decision.resource_fingerprint IS NULL
    OR decision.resource_fingerprint = payout_id::TEXT
  THEN
    RAISE EXCEPTION 'cross-tenant denial evidence leaked or omitted context';
  END IF;

  BEGIN
    PERFORM authorize_booking_payout_resource(
      provider_org, independent_actor, 'booking.payouts.service',
      'booking_supplier_payout', payout_id
    );
    RAISE EXCEPTION 'actor without payout permission was authorized';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_PAYOUT_NOT_AUTHORIZED%'
    THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM authorize_booking_payout_resource(
      customer_org, customer_owner, 'booking.payouts.read',
      'booking_supplier_payout', payout_id
    );
    RAISE EXCEPTION 'cross-tenant payout relationship was authorized';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_PAYOUT_RESOURCE_NOT_FOUND%'
    THEN RAISE; END IF;
  END;
END;
$$;

DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'authorize_booking_payout_resource(uuid,uuid,text,text,uuid)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'read_booking_supplier_payout(uuid,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'booking payout authorization functions are publicly exposed';
  END IF;
END;
$$;
