-- BS-10A durable authorization decisions and sensitive-data minimization.

DO $$
DECLARE
  allowed_org UUID := '00000000-0000-4000-8000-000000001011';
  denied_org UUID := '00000000-0000-4000-8000-000000001012';
  allowed_actor UUID := '00000000-0000-4000-8000-000000001013';
  denied_actor UUID := '00000000-0000-4000-8000-000000001014';
  resource_id TEXT := '00000000-0000-4000-8000-000000001015';
  result JSONB;
  decision booking_authorization_decisions;
BEGIN
  INSERT INTO users(id, name, email, password, role)
  VALUES
    (allowed_actor, 'Authorized Reviewer', 'booking-auth-allowed@example.test', 'x', 'farmer'),
    (denied_actor, 'Denied Reviewer', 'booking-auth-denied@example.test', 'x', 'farmer');
  INSERT INTO organizations(id, name, slug, type, status, created_by)
  VALUES
    (allowed_org, 'Authorized Tenant', 'booking-auth-allowed', 'cooperative', 'active', allowed_actor),
    (denied_org, 'Denied Tenant', 'booking-auth-denied', 'cooperative', 'active', denied_actor);
  INSERT INTO organization_memberships(
    organization_id, user_id, role, permissions, status, joined_at
  ) VALUES
    (allowed_org, allowed_actor, 'finance_manager',
      ARRAY['booking.settlements.read'], 'active', NOW()),
    (denied_org, denied_actor, 'viewer', ARRAY[]::TEXT[], 'active', NOW());

  result := evaluate_booking_authorization(
    allowed_org, allowed_actor, 'booking.settlements.read',
    'booking.organization.read', 'organization', allowed_org::TEXT,
    '00000000-0000-4000-8000-000000001016', 'booking-auth-key-allowed'
  );
  IF NOT (result->>'allowed')::BOOLEAN THEN
    RAISE EXCEPTION 'authorized booking read was denied';
  END IF;
  SELECT * INTO decision FROM booking_authorization_decisions
  WHERE id = (result->>'decision_id')::UUID;
  IF decision.outcome <> 'allowed'
    OR decision.resource_reference <> allowed_org::TEXT
    OR decision.idempotency_key_hash IS NULL
    OR decision.idempotency_key_hash = 'booking-auth-key-allowed'
  THEN RAISE EXCEPTION 'allowed authorization evidence is incomplete'; END IF;

  result := evaluate_booking_authorization(
    denied_org, denied_actor, 'booking.settlements.release',
    'booking.settlement.release', 'booking_settlement', resource_id,
    '00000000-0000-4000-8000-000000001017', 'booking-auth-key-denied'
  );
  IF (result->>'allowed')::BOOLEAN THEN
    RAISE EXCEPTION 'unauthorized booking release was allowed';
  END IF;
  SELECT * INTO decision FROM booking_authorization_decisions
  WHERE id = (result->>'decision_id')::UUID;
  IF decision.outcome <> 'denied'
    OR decision.resource_reference IS NOT NULL
    OR decision.resource_fingerprint IS NULL
    OR decision.reason_code <> 'MEMBERSHIP_OR_PERMISSION_DENIED'
  THEN RAISE EXCEPTION 'denied evidence leaked or omitted protected context'; END IF;

  BEGIN
    UPDATE booking_authorization_decisions SET reason_code = 'TAMPERED'
    WHERE id = decision.id;
    RAISE EXCEPTION 'authorization evidence was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%BOOKING_AUTHORIZATION_EVIDENCE_IMMUTABLE%'
    THEN RAISE; END IF;
  END;
END;
$$;

DO $$
BEGIN
  IF has_table_privilege(
    'service_role', 'booking_authorization_decisions', 'INSERT'
  ) OR has_table_privilege(
    'service_role', 'booking_authorization_decisions', 'UPDATE'
  ) OR has_table_privilege(
    'service_role', 'booking_authorization_decisions', 'DELETE'
  ) THEN RAISE EXCEPTION 'service role can directly mutate booking authorization evidence';
  END IF;
END;
$$;
