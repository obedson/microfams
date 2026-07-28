-- FC-05 booking payment retry and expiry recovery.

ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS retry_of_payment_id UUID REFERENCES payments(id),
  ADD COLUMN IF NOT EXISTS attempt_number INTEGER;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY organization_id, source_type, source_id
    ORDER BY created_at, id
  )::INTEGER AS attempt_number
  FROM payments
)
UPDATE payments payment
SET attempt_number = ranked.attempt_number
FROM ranked
WHERE payment.id = ranked.id
  AND payment.attempt_number IS DISTINCT FROM ranked.attempt_number;

ALTER TABLE payments
  ALTER COLUMN attempt_number SET DEFAULT 1,
  ALTER COLUMN attempt_number SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'payments_attempt_number_positive'
      AND conrelid = 'payments'::regclass
  ) THEN
    ALTER TABLE payments ADD CONSTRAINT payments_attempt_number_positive
      CHECK (attempt_number > 0);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_source_attempt
  ON payments(organization_id, source_type, source_id, attempt_number);

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_active_source
  ON payments(organization_id, source_type, source_id)
  WHERE state IN ('created', 'requires_action', 'processing');

CREATE OR REPLACE FUNCTION create_payment_intent(
  p_organization_id UUID, p_source_type TEXT, p_source_id UUID, p_payer_id UUID,
  p_internal_reference TEXT, p_idempotency_key TEXT, p_provider_name TEXT,
  p_provider_environment TEXT, p_currency TEXT, p_amount_minor BIGINT,
  p_correlation_id UUID, p_actor_id UUID
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_existing payments;
  v_previous_payment payments;
  v_result payments;
  v_hash TEXT;
  v_previous TEXT;
  v_attempt_number INTEGER;
BEGIN
  IF p_source_type NOT IN ('booking', 'marketplace_order', 'wallet', 'group_membership', 'contribution')
    OR p_source_id IS NULL THEN RAISE EXCEPTION 'Payment source is invalid'; END IF;
  IF p_amount_minor <= 0 OR upper(p_currency) <> 'NGN' THEN RAISE EXCEPTION 'Payment money is invalid'; END IF;
  IF p_provider_environment NOT IN ('deterministic', 'sandbox', 'live') THEN RAISE EXCEPTION 'Provider environment is invalid'; END IF;
  IF p_internal_reference IS NULL OR length(p_internal_reference) NOT BETWEEN 8 AND 160
    OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    THEN RAISE EXCEPTION 'Payment references are invalid'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    concat_ws('|', p_organization_id, p_source_type, p_source_id), 0
  ));

  v_hash := encode(digest(convert_to(concat_ws('|', p_organization_id, p_source_type, p_source_id,
    p_payer_id, p_internal_reference, p_provider_name, p_provider_environment, upper(p_currency),
    p_amount_minor, p_correlation_id, p_actor_id), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM payments
    WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key FOR UPDATE;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'Payment replay changed the original request'; END IF;
    RETURN v_existing;
  END IF;

  IF EXISTS (
    SELECT 1 FROM payments
    WHERE organization_id = p_organization_id
      AND source_type = p_source_type
      AND source_id = p_source_id
      AND state IN ('created', 'requires_action', 'processing')
  ) THEN
    RAISE EXCEPTION 'Payment source already has an active attempt';
  END IF;

  SELECT * INTO v_previous_payment
  FROM payments
  WHERE organization_id = p_organization_id
    AND source_type = p_source_type
    AND source_id = p_source_id
  ORDER BY attempt_number DESC
  LIMIT 1;
  v_attempt_number := COALESCE(v_previous_payment.attempt_number, 0) + 1;

  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payments(
    organization_id, source_type, source_id, payer_id, internal_reference,
    idempotency_key, request_hash, provider_name, provider_environment, currency,
    amount_minor, correlation_id, actor_id, retry_of_payment_id, attempt_number
  ) VALUES (
    p_organization_id, p_source_type, p_source_id, p_payer_id, p_internal_reference,
    p_idempotency_key, v_hash, p_provider_name, p_provider_environment, upper(p_currency),
    p_amount_minor, p_correlation_id, p_actor_id, v_previous_payment.id, v_attempt_number
  ) RETURNING * INTO v_result;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION create_booking_payment_retry(
  p_organization_id UUID, p_booking_id UUID, p_payer_id UUID,
  p_internal_reference TEXT, p_idempotency_key TEXT, p_provider_name TEXT,
  p_provider_environment TEXT, p_amount_minor BIGINT, p_correlation_id UUID,
  p_actor_id UUID, p_max_retries INTEGER
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_booking bookings;
  v_latest payments;
  v_existing payments;
  v_result payments;
  v_next_retry_count INTEGER;
BEGIN
  IF p_max_retries < 0 OR p_max_retries > 20 THEN
    RAISE EXCEPTION 'Payment retry policy is invalid';
  END IF;
  SELECT * INTO v_booking FROM bookings
  WHERE id = p_booking_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
  IF v_booking.farmer_id <> p_payer_id OR p_actor_id <> p_payer_id THEN
    RAISE EXCEPTION 'Only the booking farmer can retry payment';
  END IF;
  SELECT * INTO v_existing FROM payments
  WHERE organization_id = p_organization_id
    AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NULL THEN
    IF v_booking.status <> 'pending_payment' OR v_booking.payment_status <> 'failed' THEN
      RAISE EXCEPTION 'Booking payment is not retryable';
    END IF;
    IF v_booking.payment_retry_count >= p_max_retries THEN
      RAISE EXCEPTION 'Maximum payment retry attempts exceeded';
    END IF;
  END IF;
  IF round(v_booking.total_amount * 100)::BIGINT <> p_amount_minor THEN
    RAISE EXCEPTION 'Booking payment amount mismatch';
  END IF;

  SELECT * INTO v_existing FROM payments
  WHERE organization_id = p_organization_id
    AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    v_result := create_payment_intent(
      p_organization_id, 'booking', p_booking_id, p_payer_id,
      p_internal_reference, p_idempotency_key, p_provider_name,
      p_provider_environment, 'NGN', p_amount_minor, p_correlation_id, p_actor_id
    );
    UPDATE bookings SET
      payment_reference = v_result.internal_reference,
      payment_retry_count = GREATEST(payment_retry_count, v_result.attempt_number - 1),
      payment_status = 'pending',
      payment_timeout_at = COALESCE(payment_timeout_at, NOW() + INTERVAL '48 hours'),
      updated_at = NOW()
    WHERE id = p_booking_id;
    RETURN v_result;
  END IF;

  SELECT * INTO v_latest FROM payments
  WHERE organization_id = p_organization_id
    AND source_type = 'booking'
    AND source_id = p_booking_id
  ORDER BY attempt_number DESC
  LIMIT 1;
  IF v_latest.id IS NOT NULL
    AND v_latest.state NOT IN ('failed', 'cancelled', 'expired') THEN
    RAISE EXCEPTION 'Previous booking payment is not terminal';
  END IF;
  v_next_retry_count := CASE WHEN v_latest.id IS NULL
    THEN v_booking.payment_retry_count + 1
    ELSE v_latest.attempt_number
  END;

  v_result := create_payment_intent(
    p_organization_id, 'booking', p_booking_id, p_payer_id,
    p_internal_reference, p_idempotency_key, p_provider_name,
    p_provider_environment, 'NGN', p_amount_minor, p_correlation_id, p_actor_id
  );

  UPDATE bookings SET
    payment_reference = v_result.internal_reference,
    payment_retry_count = GREATEST(v_next_retry_count, v_result.attempt_number - 1),
    payment_status = 'pending',
    payment_timeout_at = NOW() + INTERVAL '48 hours',
    updated_at = NOW()
  WHERE id = p_booking_id;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_expired_booking_payment(p_payment_id UUID)
RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_booking bookings; v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND OR v_payment.source_type <> 'booking' THEN RAISE EXCEPTION 'Booking payment not found'; END IF;
  IF v_payment.action_expires_at IS NULL OR v_payment.action_expires_at > NOW() THEN
    RAISE EXCEPTION 'Booking payment has not expired';
  END IF;
  IF v_payment.state NOT IN ('requires_action', 'failed', 'cancelled', 'expired') THEN
    RAISE EXCEPTION 'Booking payment is not eligible for timeout cancellation';
  END IF;
  SELECT * INTO v_booking FROM bookings
  WHERE id = v_payment.source_id
    AND organization_id = v_payment.organization_id
    AND payment_reference = v_payment.internal_reference
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking is not linked to the expiring payment'; END IF;
  IF v_booking.status = 'cancelled' AND v_booking.payment_status = 'failed' THEN
    RETURN v_payment;
  END IF;

  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  IF v_payment.state = 'requires_action' THEN
    UPDATE payments SET state = 'expired', failure_code = 'PAYMENT_WINDOW_EXPIRED',
      failure_reason = 'Payment authorization window expired', terminal_at = NOW(), updated_at = NOW()
    WHERE id = v_payment.id RETURNING * INTO v_payment;
  END IF;
  UPDATE bookings SET status = 'cancelled', payment_status = 'failed',
    rejection_reason = 'Payment not completed within the 48-hour payment window',
    cancelled_at = NOW(), updated_at = NOW()
  WHERE id = v_booking.id;
  INSERT INTO audit_logs(user_id, action, resource_type, resource_id, details)
  VALUES (NULL, 'booking_cancelled_payment_timeout', 'booking', v_booking.id,
    jsonb_build_object('organization_id', v_payment.organization_id, 'payment_id', v_payment.id,
      'attempt_number', v_payment.attempt_number));
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_payment;
END;
$$;

CREATE TABLE IF NOT EXISTS payment_authorizations (
  payment_id UUID PRIMARY KEY REFERENCES payments(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES organizations(id),
  authorization_url TEXT NOT NULL CHECK (
    length(authorization_url) <= 2048 AND authorization_url ~ '^https://'
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE payment_authorizations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE payment_authorizations FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION record_payment_authorization_url(
  p_payment_id UUID, p_authorization_url TEXT
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_existing TEXT;
BEGIN
  IF p_authorization_url IS NULL OR length(p_authorization_url) > 2048
    OR p_authorization_url !~ '^https://' THEN
    RAISE EXCEPTION 'Payment authorization URL is invalid';
  END IF;
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF v_payment.state NOT IN ('requires_action', 'processing') THEN
    RAISE EXCEPTION 'Payment cannot accept an authorization URL in its current state';
  END IF;
  SELECT authorization_url INTO v_existing
  FROM payment_authorizations WHERE payment_id = p_payment_id;
  IF v_existing IS NOT NULL AND v_existing <> p_authorization_url THEN
    RAISE EXCEPTION 'Payment authorization URL cannot be replaced';
  END IF;
  INSERT INTO payment_authorizations(payment_id, organization_id, authorization_url)
  VALUES (p_payment_id, v_payment.organization_id, p_authorization_url)
  ON CONFLICT (payment_id) DO NOTHING;
  RETURN COALESCE(v_existing, p_authorization_url);
END;
$$;

CREATE OR REPLACE FUNCTION get_payment_authorization_url(p_payment_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT authorization_url FROM payment_authorizations WHERE payment_id = p_payment_id;
$$;
REVOKE ALL ON FUNCTION create_booking_payment_retry(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, UUID, UUID, INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION cancel_expired_booking_payment(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION create_booking_payment_retry(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, UUID, UUID, INTEGER)
  TO service_role;
REVOKE ALL ON FUNCTION record_payment_authorization_url(UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION get_payment_authorization_url(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION cancel_expired_booking_payment(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION record_payment_authorization_url(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION get_payment_authorization_url(UUID) TO service_role;
