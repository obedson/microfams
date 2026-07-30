BEGIN;

DO $$
DECLARE
  v_booking bookings;
  v_deliver_id UUID;
  v_dead_letter_id UUID;
  v_claimed booking_domain_notification_outbox;
  v_now TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
BEGIN
  SELECT booking.* INTO v_booking
  FROM bookings AS booking
  JOIN organization_memberships AS membership
    ON membership.organization_id = booking.organization_id
   AND membership.status = 'active'
  ORDER BY booking.created_at, booking.id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking notification fixture is unavailable';
  END IF;

  v_deliver_id := enqueue_booking_domain_notification(
    v_booking.organization_id,
    v_booking.organization_id,
    v_booking.id,
    NULL,
    'recovery',
    'schema:booking-notification:delivery:' || v_booking.id::TEXT,
    jsonb_build_object('fixture', 'delivery'),
    v_now
  );
  SELECT claimed.* INTO v_claimed
  FROM claim_booking_domain_notifications(
    'schema-booking-worker', v_now, 60, 20
  ) AS claimed
  WHERE claimed.id = v_deliver_id;
  SELECT outbox.* INTO v_claimed
  FROM booking_domain_notification_outbox AS outbox
  WHERE outbox.id = v_deliver_id;
  IF v_claimed.id <> v_deliver_id OR v_claimed.state <> 'leased'
    OR v_claimed.attempt_count <> 1
    OR v_claimed.lease_owner <> 'schema-booking-worker'
    OR v_claimed.lease_expires_at <> v_now + INTERVAL '60 seconds'
  THEN
    RAISE EXCEPTION 'booking notification lease was not recorded: state=%, attempts=%, owner=%, expiry=%, available=%, next=%',
      v_claimed.state, v_claimed.attempt_count,
      v_claimed.lease_owner, v_claimed.lease_expires_at,
      v_claimed.available_at, v_claimed.next_attempt_at;
  END IF;
  PERFORM deliver_booking_domain_notification(
    v_deliver_id, 'schema-booking-worker', v_now + INTERVAL '1 second'
  );
  IF NOT EXISTS (
    SELECT 1 FROM booking_domain_notification_outbox
    WHERE id = v_deliver_id AND state = 'delivered'
      AND delivered_at = v_now + INTERVAL '1 second'
  ) OR NOT EXISTS (
    SELECT 1 FROM notifications
    WHERE source_type = 'booking_domain_event' AND source_id = v_deliver_id
      AND organization_id = v_booking.organization_id
  ) THEN
    RAISE EXCEPTION 'booking notification delivery was not durable';
  END IF;

  v_dead_letter_id := enqueue_booking_domain_notification(
    v_booking.organization_id,
    v_booking.organization_id,
    v_booking.id,
    NULL,
    'reversal',
    'schema:booking-notification:dead-letter:' || v_booking.id::TEXT,
    jsonb_build_object('fixture', 'dead-letter'),
    v_now
  );
  PERFORM set_config('microfams.booking_notification_engine', 'on', TRUE);
  UPDATE booking_domain_notification_outbox
  SET max_attempts = 1
  WHERE id = v_dead_letter_id;
  PERFORM claimed.id
  FROM claim_booking_domain_notifications(
    'schema-booking-worker', v_now, 60, 20
  ) AS claimed
  WHERE claimed.id = v_dead_letter_id;
  PERFORM fail_booking_domain_notification(
    v_dead_letter_id,
    'schema-booking-worker',
    'SYNTHETIC_DELIVERY_FAILURE',
    v_now + INTERVAL '2 seconds'
  );
  IF NOT EXISTS (
    SELECT 1 FROM booking_domain_notification_outbox
    WHERE id = v_dead_letter_id AND state = 'dead_letter'
      AND attempt_count = 1
      AND failure_code = 'SYNTHETIC_DELIVERY_FAILURE'
      AND dead_lettered_at = v_now + INTERVAL '2 seconds'
  ) THEN
    RAISE EXCEPTION 'booking notification dead-letter evidence is incomplete';
  END IF;
END $$;

ROLLBACK;
SELECT 'booking notification outbox schema tests passed' AS result;
