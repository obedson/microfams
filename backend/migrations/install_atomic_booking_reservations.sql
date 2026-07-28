-- Atomic, tenant-safe booking reservations with immutable pricing evidence.

CREATE TABLE IF NOT EXISTS booking_price_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL UNIQUE REFERENCES bookings(id),
  property_id UUID NOT NULL REFERENCES properties(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  monthly_rate_minor BIGINT NOT NULL CHECK (monthly_rate_minor >= 0),
  duration_days INTEGER NOT NULL CHECK (duration_days > 0),
  billed_months INTEGER NOT NULL CHECK (billed_months > 0),
  total_minor BIGINT NOT NULL CHECK (total_minor >= 0),
  pricing_version TEXT NOT NULL DEFAULT 'BOOKING-MONTHLY-2026-07-28',
  source TEXT NOT NULL DEFAULT 'property.price_per_month',
  captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS booking_reservation_holds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL UNIQUE REFERENCES bookings(id),
  property_id UUID NOT NULL REFERENCES properties(id),
  actor_id UUID NOT NULL REFERENCES users(id),
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'converted', 'released', 'expired')),
  held_until TIMESTAMPTZ NOT NULL,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (end_date > start_date),
  UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_booking_price_snapshots_tenant ON booking_price_snapshots(organization_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_reservation_holds_property ON booking_reservation_holds(property_id, held_until) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS idx_booking_reservation_holds_tenant ON booking_reservation_holds(organization_id, created_at DESC);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'bookings'::regclass AND conname = 'bookings_dates_strict') THEN
    ALTER TABLE bookings ADD CONSTRAINT bookings_dates_strict CHECK (end_date > start_date) NOT VALID;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION reject_booking_price_snapshot_mutation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Booking price snapshots are immutable';
END;
$$;
DROP TRIGGER IF EXISTS booking_price_snapshots_immutable ON booking_price_snapshots;
CREATE TRIGGER booking_price_snapshots_immutable BEFORE UPDATE OR DELETE ON booking_price_snapshots
  FOR EACH ROW EXECUTE FUNCTION reject_booking_price_snapshot_mutation();

CREATE OR REPLACE FUNCTION enforce_booking_reservation_exclusivity()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NEW.status IN ('pending_payment', 'pending', 'confirmed') THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.property_id::TEXT, 0));
    IF EXISTS (
      SELECT 1 FROM bookings existing
      WHERE existing.property_id = NEW.property_id AND existing.id <> NEW.id
        AND existing.deleted_at IS NULL
        AND existing.status IN ('pending_payment', 'pending', 'confirmed')
        AND daterange(existing.start_date, existing.end_date, '[]') && daterange(NEW.start_date, NEW.end_date, '[]')
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '23P01', MESSAGE = 'BOOKING_DATES_UNAVAILABLE';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_booking_reservation_exclusivity_trigger ON bookings;
CREATE TRIGGER enforce_booking_reservation_exclusivity_trigger
  BEFORE INSERT OR UPDATE OF property_id, start_date, end_date, status, deleted_at ON bookings
  FOR EACH ROW EXECUTE FUNCTION enforce_booking_reservation_exclusivity();

CREATE OR REPLACE FUNCTION sync_booking_reservation_hold()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.status = 'confirmed' OR NEW.payment_status = 'paid' THEN
    UPDATE booking_reservation_holds SET state = 'converted', updated_at = NOW()
    WHERE booking_id = NEW.id AND state = 'active';
  ELSIF NEW.status IN ('cancelled', 'completed') OR NEW.deleted_at IS NOT NULL THEN
    UPDATE booking_reservation_holds SET
      state = CASE WHEN OLD.payment_timeout_at IS NOT NULL AND NOW() >= OLD.payment_timeout_at THEN 'expired' ELSE 'released' END,
      updated_at = NOW()
    WHERE booking_id = NEW.id AND state = 'active';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS sync_booking_reservation_hold_trigger ON bookings;
CREATE TRIGGER sync_booking_reservation_hold_trigger AFTER UPDATE OF status, payment_status, deleted_at ON bookings
  FOR EACH ROW EXECUTE FUNCTION sync_booking_reservation_hold();

CREATE OR REPLACE FUNCTION create_booking_reservation(
  p_organization_id UUID, p_actor_id UUID, p_property_id UUID,
  p_start_date DATE, p_end_date DATE, p_notes TEXT,
  p_idempotency_key TEXT, p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_property properties;
  v_provider organizations;
  v_existing booking_reservation_holds;
  v_booking bookings;
  v_snapshot booking_price_snapshots;
  v_hold booking_reservation_holds;
  v_request_hash TEXT;
  v_duration_days INTEGER;
  v_billed_months INTEGER;
  v_monthly_rate_minor BIGINT;
  v_total_minor BIGINT;
  v_held_until TIMESTAMPTZ := NOW() + INTERVAL '48 hours';
BEGIN
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_INVALID'; END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date <= p_start_date THEN RAISE EXCEPTION 'BOOKING_DATES_INVALID'; END IF;
  IF p_start_date < CURRENT_DATE THEN RAISE EXCEPTION 'BOOKING_START_DATE_PAST'; END IF;
  IF length(COALESCE(p_notes, '')) > 2000 THEN RAISE EXCEPTION 'BOOKING_NOTES_TOO_LONG'; END IF;

  v_request_hash := encode(digest(convert_to(concat_ws('|', p_organization_id, p_actor_id,
    p_property_id, p_start_date, p_end_date, COALESCE(btrim(p_notes), '')), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization_id::TEXT || ':' || p_idempotency_key, 0));
  SELECT * INTO v_existing FROM booking_reservation_holds
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_request_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    SELECT * INTO v_booking FROM bookings WHERE id = v_existing.booking_id;
    SELECT * INTO v_snapshot FROM booking_price_snapshots WHERE booking_id = v_existing.booking_id;
    RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'price_snapshot', to_jsonb(v_snapshot),
      'hold', to_jsonb(v_existing), 'idempotency_replay', TRUE);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id AND status = 'active')
  THEN RAISE EXCEPTION 'BOOKING_NOT_AUTHORIZED'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_property_id::TEXT, 0));
  SELECT * INTO v_property FROM properties WHERE id = p_property_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPERTY_NOT_FOUND'; END IF;
  SELECT * INTO v_provider FROM organizations WHERE id = v_property.organization_id;
  IF v_provider.id IS NULL OR v_provider.status <> 'active' THEN RAISE EXCEPTION 'PROVIDER_NOT_AVAILABLE'; END IF;
  IF NOT v_property.is_active THEN RAISE EXCEPTION 'PROPERTY_NOT_AVAILABLE'; END IF;
  IF p_start_date < v_property.available_from OR p_end_date > v_property.available_to THEN
    RAISE EXCEPTION 'BOOKING_OUTSIDE_PROPERTY_AVAILABILITY';
  END IF;
  IF EXISTS (
    SELECT 1 FROM bookings existing
    WHERE existing.property_id = p_property_id AND existing.deleted_at IS NULL
      AND existing.status IN ('pending_payment', 'pending', 'confirmed')
      AND daterange(existing.start_date, existing.end_date, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) THEN RAISE EXCEPTION 'BOOKING_DATES_UNAVAILABLE' USING ERRCODE = '23P01'; END IF;

  v_duration_days := p_end_date - p_start_date;
  v_billed_months := CEIL(v_duration_days::NUMERIC / 30)::INTEGER;
  v_monthly_rate_minor := ROUND(v_property.price_per_month * 100)::BIGINT;
  v_total_minor := v_monthly_rate_minor * v_billed_months;

  INSERT INTO bookings(organization_id, provider_organization_id, property_id, farmer_id,
    start_date, end_date, total_amount, status, payment_status, payment_retry_count, payment_timeout_at, notes)
  VALUES (p_organization_id, v_property.organization_id, p_property_id, p_actor_id,
    p_start_date, p_end_date, v_total_minor::NUMERIC / 100, 'pending_payment', 'pending', 0, v_held_until, NULLIF(btrim(p_notes), ''))
  RETURNING * INTO v_booking;

  INSERT INTO booking_price_snapshots(organization_id, provider_organization_id, booking_id, property_id,
    currency, monthly_rate_minor, duration_days, billed_months, total_minor)
  VALUES (p_organization_id, v_property.organization_id, v_booking.id, p_property_id,
    v_provider.default_currency, v_monthly_rate_minor, v_duration_days, v_billed_months, v_total_minor)
  RETURNING * INTO v_snapshot;

  INSERT INTO booking_reservation_holds(organization_id, provider_organization_id, booking_id, property_id,
    actor_id, start_date, end_date, held_until, idempotency_key, request_hash, correlation_id)
  VALUES (p_organization_id, v_property.organization_id, v_booking.id, p_property_id,
    p_actor_id, p_start_date, p_end_date, v_held_until, p_idempotency_key, v_request_hash, p_correlation_id)
  RETURNING * INTO v_hold;

  INSERT INTO organization_audit_log(organization_id, actor_id, action, resource_type, resource_id, after_value)
  VALUES
    (p_organization_id, p_actor_id, 'booking.reservation.created', 'booking', v_booking.id::TEXT,
      jsonb_build_object('property_id', p_property_id, 'provider_organization_id', v_property.organization_id,
        'start_date', p_start_date, 'end_date', p_end_date, 'total_minor', v_total_minor,
        'currency', v_provider.default_currency, 'held_until', v_held_until, 'correlation_id', p_correlation_id)),
    (v_property.organization_id, p_actor_id, 'booking.reservation.received', 'booking', v_booking.id::TEXT,
      jsonb_build_object('customer_organization_id', p_organization_id, 'property_id', p_property_id,
        'start_date', p_start_date, 'end_date', p_end_date, 'held_until', v_held_until, 'correlation_id', p_correlation_id));

  RETURN jsonb_build_object('booking', to_jsonb(v_booking), 'price_snapshot', to_jsonb(v_snapshot),
    'hold', to_jsonb(v_hold), 'idempotency_replay', FALSE);
END;
$$;

ALTER TABLE booking_price_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_reservation_holds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_price_snapshots, booking_reservation_holds FROM anon, authenticated;
REVOKE ALL ON FUNCTION create_booking_reservation(UUID, UUID, UUID, DATE, DATE, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_booking_reservation(UUID, UUID, UUID, DATE, DATE, TEXT, TEXT, UUID) TO service_role;
