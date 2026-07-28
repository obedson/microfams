-- Canonical, tenant-safe owner approval and completion for property bookings.

CREATE TABLE IF NOT EXISTS booking_state_transitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  acting_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL REFERENCES bookings(id),
  actor_id UUID NOT NULL REFERENCES users(id),
  from_status TEXT NOT NULL,
  to_status TEXT NOT NULL CHECK (to_status IN ('confirmed', 'completed')),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (acting_organization_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_booking_state_transitions_booking
  ON booking_state_transitions(booking_id, created_at);
CREATE INDEX IF NOT EXISTS idx_booking_state_transitions_tenant
  ON booking_state_transitions(organization_id, created_at DESC);

CREATE OR REPLACE FUNCTION transition_booking_state(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_target_status TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_booking bookings;
  v_owner_id UUID;
  v_timezone TEXT;
  v_existing booking_state_transitions;
  v_transition booking_state_transitions;
  v_request_hash TEXT;
BEGIN
  IF p_target_status NOT IN ('confirmed', 'completed') THEN
    RAISE EXCEPTION 'BOOKING_TRANSITION_TARGET_INVALID';
  END IF;
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_INVALID';
  END IF;

  v_request_hash := encode(digest(convert_to(concat_ws('|', p_booking_id,
    p_acting_organization_id, p_actor_id, p_target_status), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_acting_organization_id::TEXT || ':' || p_idempotency_key, 0));

  SELECT * INTO v_existing FROM booking_state_transitions
  WHERE acting_organization_id = p_acting_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT';
    END IF;
    SELECT * INTO v_booking FROM bookings WHERE id = v_existing.booking_id;
    RETURN jsonb_build_object('transition', to_jsonb(v_existing),
      'booking', to_jsonb(v_booking), 'idempotency_replay', TRUE);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_booking_id::TEXT, 0));
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_NOT_FOUND'; END IF;

  SELECT p.owner_id, o.timezone INTO v_owner_id, v_timezone
  FROM properties p JOIN organizations o ON o.id = v_booking.provider_organization_id
  WHERE p.id = v_booking.property_id AND p.organization_id = v_booking.provider_organization_id;
  IF v_owner_id IS NULL THEN RAISE EXCEPTION 'BOOKING_PROVIDER_INVALID'; END IF;

  IF p_acting_organization_id <> v_booking.provider_organization_id OR NOT EXISTS (
    SELECT 1 FROM organization_memberships m
    WHERE m.organization_id = p_acting_organization_id
      AND m.user_id = p_actor_id AND m.status = 'active'
  ) THEN RAISE EXCEPTION 'BOOKING_TRANSITION_NOT_AUTHORIZED'; END IF;

  IF p_actor_id <> v_owner_id AND NOT EXISTS (
    SELECT 1 FROM organization_memberships m
    WHERE m.organization_id = p_acting_organization_id
      AND m.user_id = p_actor_id AND m.status = 'active'
      AND ('booking.lifecycle.manage' = ANY(m.permissions) OR 'booking.*' = ANY(m.permissions))
  ) THEN RAISE EXCEPTION 'BOOKING_TRANSITION_NOT_AUTHORIZED'; END IF;

  IF p_target_status = 'confirmed' THEN
    IF v_booking.status <> 'pending' THEN RAISE EXCEPTION 'BOOKING_TRANSITION_INVALID'; END IF;
    IF v_booking.payment_status <> 'paid' THEN RAISE EXCEPTION 'BOOKING_PAYMENT_REQUIRED'; END IF;
  ELSE
    IF v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'BOOKING_TRANSITION_INVALID'; END IF;
    IF v_booking.payment_status <> 'paid' THEN RAISE EXCEPTION 'BOOKING_PAYMENT_REQUIRED'; END IF;
    IF (NOW() AT TIME ZONE COALESCE(v_timezone, 'Africa/Lagos'))::DATE < v_booking.end_date THEN
      RAISE EXCEPTION 'BOOKING_COMPLETION_TOO_EARLY';
    END IF;
  END IF;

  PERFORM set_config('microfams.actor_id', p_actor_id::TEXT, TRUE);
  UPDATE bookings SET status = p_target_status, updated_at = NOW()
  WHERE id = v_booking.id RETURNING * INTO v_booking;

  INSERT INTO booking_state_transitions(
    organization_id, provider_organization_id, acting_organization_id,
    booking_id, actor_id, from_status, to_status, idempotency_key,
    request_hash, correlation_id
  ) VALUES (
    v_booking.organization_id, v_booking.provider_organization_id,
    p_acting_organization_id, v_booking.id, p_actor_id,
    CASE p_target_status WHEN 'confirmed' THEN 'pending' ELSE 'confirmed' END,
    p_target_status, p_idempotency_key, v_request_hash, p_correlation_id
  ) RETURNING * INTO v_transition;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value
  ) VALUES (
    v_booking.provider_organization_id, p_actor_id,
    'booking.' || p_target_status, 'booking', v_booking.id::TEXT,
    jsonb_build_object('status', v_transition.from_status),
    jsonb_build_object('status', p_target_status,
      'customer_organization_id', v_booking.organization_id,
      'correlation_id', p_correlation_id)
  );
  IF v_booking.organization_id <> v_booking.provider_organization_id THEN
    INSERT INTO organization_audit_log(
      organization_id, actor_id, action, resource_type, resource_id,
      before_value, after_value
    ) VALUES (
      v_booking.organization_id, p_actor_id,
      'booking.' || p_target_status, 'booking', v_booking.id::TEXT,
      jsonb_build_object('status', v_transition.from_status),
      jsonb_build_object('status', p_target_status,
        'provider_organization_id', v_booking.provider_organization_id,
        'correlation_id', p_correlation_id)
    );
  END IF;

  RETURN jsonb_build_object('transition', to_jsonb(v_transition),
    'booking', to_jsonb(v_booking), 'idempotency_replay', FALSE);
END;
$$;

-- Existing group-fund booking payments must also enter pending owner approval.
CREATE OR REPLACE FUNCTION process_group_fund_payment(
  p_booking_id UUID, p_group_id UUID, p_amount NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_group groups;
BEGIN
  PERFORM wallet_major_to_minor(p_amount);
  SELECT * INTO v_group FROM groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Group not found'; END IF;
  IF wallet_cutover_is_active(v_group.organization_id) THEN
    RAISE EXCEPTION 'Active cutover booking payment requires the approved cross-organization settlement mapping';
  END IF;
  IF v_group.group_fund_balance < p_amount THEN RAISE EXCEPTION 'Insufficient group funds'; END IF;
  UPDATE groups SET group_fund_balance = group_fund_balance - p_amount, updated_at = NOW()
  WHERE id = p_group_id;
  UPDATE bookings SET payment_status = 'paid', status = 'pending', updated_at = NOW()
  WHERE id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
  RETURN jsonb_build_object('booking_id', p_booking_id, 'group_id', p_group_id,
    'amount', p_amount, 'status', 'EXECUTED');
END;
$$;

ALTER TABLE booking_state_transitions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_state_transitions FROM anon, authenticated;
REVOKE ALL ON FUNCTION transition_booking_state(UUID, UUID, UUID, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION transition_booking_state(UUID, UUID, UUID, TEXT, TEXT, UUID) TO service_role;
