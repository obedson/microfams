BEGIN;

DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  v_farmer_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  booking_id UUID;
  initial_payment payments;
  retry_payment payments;
  replay payments;
BEGIN
  SELECT b.id INTO booking_id
  FROM bookings b
  WHERE b.organization_id = tenant_id AND b.farmer_id = v_farmer_id
  ORDER BY b.created_at
  LIMIT 1;
  IF booking_id IS NULL THEN RAISE EXCEPTION 'booking recovery fixture is missing'; END IF;

  UPDATE bookings SET status = 'pending_payment', payment_status = 'failed',
    payment_retry_count = 0, payment_reference = NULL, payment_timeout_at = NULL
  WHERE id = booking_id;

  initial_payment := create_payment_intent(
    tenant_id, 'booking', booking_id, v_farmer_id, 'BOOK-schema-initial-001',
    'schema-booking-initial-key', 'deterministic', 'deterministic', 'NGN', 1000000,
    '00000000-0000-4000-8000-000000009201', v_farmer_id
  );
  initial_payment := mark_payment_initialized(initial_payment.id, repeat('e', 64),
    'BOOK-schema-initial-001', 'requires_action', NOW() + INTERVAL '1 hour');
  initial_payment := fail_inbound_payment(initial_payment.id, 'failed', 'DECLINED', 'Test decline');
  UPDATE bookings SET payment_reference = initial_payment.internal_reference WHERE id = booking_id;

  retry_payment := create_booking_payment_retry(
    tenant_id, booking_id, v_farmer_id, 'BOOK-schema-retry-001',
    'schema-booking-retry-key', 'deterministic', 'deterministic', 1000000,
    '00000000-0000-4000-8000-000000009202', v_farmer_id, 3
  );
  replay := create_booking_payment_retry(
    tenant_id, booking_id, v_farmer_id, 'BOOK-schema-retry-001',
    'schema-booking-retry-key', 'deterministic', 'deterministic', 1000000,
    '00000000-0000-4000-8000-000000009202', v_farmer_id, 3
  );

  IF retry_payment.id <> replay.id OR retry_payment.attempt_number <> 2
    OR retry_payment.retry_of_payment_id <> initial_payment.id THEN
    RAISE EXCEPTION 'booking retry was not linked and idempotent';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM bookings WHERE id = booking_id
      AND payment_reference = retry_payment.internal_reference
      AND payment_retry_count = 1 AND payment_status = 'pending'
      AND payment_timeout_at >= NOW() + INTERVAL '47 hours 59 minutes'
  ) THEN RAISE EXCEPTION 'booking retry state was not synchronized'; END IF;

  BEGIN
    PERFORM create_payment_intent(
      tenant_id, 'booking', booking_id, v_farmer_id, 'BOOK-schema-active-002',
      'schema-booking-active-key', 'deterministic', 'deterministic', 'NGN', 1000000,
      '00000000-0000-4000-8000-000000009203', v_farmer_id
    );
    RAISE EXCEPTION 'parallel active booking payment was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'parallel active booking payment was accepted' THEN RAISE; END IF;
  END;

  retry_payment := mark_payment_initialized(retry_payment.id, repeat('f', 64),
    'BOOK-schema-retry-001', 'requires_action', NOW() - INTERVAL '1 minute');
  PERFORM record_payment_authorization_url(
    retry_payment.id, 'https://payments.example.test/authorize/schema-retry'
  );
  PERFORM record_payment_authorization_url(
    retry_payment.id, 'https://payments.example.test/authorize/schema-retry'
  );
  IF get_payment_authorization_url(retry_payment.id)
      <> 'https://payments.example.test/authorize/schema-retry' THEN
    RAISE EXCEPTION 'payment authorization URL replay was not idempotent';
  END IF;
  retry_payment := cancel_expired_booking_payment(retry_payment.id);
  replay := cancel_expired_booking_payment(retry_payment.id);

  IF retry_payment.state <> 'expired' OR replay.id <> retry_payment.id THEN
    RAISE EXCEPTION 'expired booking payment cancellation was not idempotent';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM bookings WHERE id = booking_id
      AND status = 'cancelled' AND payment_status = 'failed'
  ) THEN RAISE EXCEPTION 'expired payment did not cancel the booking'; END IF;
  IF (SELECT count(*) FROM audit_logs
      WHERE action = 'booking_cancelled_payment_timeout' AND resource_id = booking_id) <> 1 THEN
    RAISE EXCEPTION 'timeout cancellation audit was duplicated';
  END IF;

  BEGIN
    PERFORM create_booking_payment_retry(
      tenant_id, booking_id, '00000000-0000-4000-8000-000000000101',
      'BOOK-schema-foreign-001', 'schema-booking-foreign-key', 'deterministic',
      'deterministic', 1000000, '00000000-0000-4000-8000-000000009204',
      '00000000-0000-4000-8000-000000000101', 3
    );
    RAISE EXCEPTION 'non-farmer booking retry was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'non-farmer booking retry was accepted' THEN RAISE; END IF;
  END;
END $$;

DO $$
BEGIN
  IF has_function_privilege('anon',
      'create_booking_payment_retry(uuid,uuid,uuid,text,text,text,text,bigint,uuid,uuid,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated',
      'create_booking_payment_retry(uuid,uuid,uuid,text,text,text,text,bigint,uuid,uuid,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role',
      'create_booking_payment_retry(uuid,uuid,uuid,text,text,text,text,bigint,uuid,uuid,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'cancel_expired_booking_payment(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'cancel_expired_booking_payment(uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'cancel_expired_booking_payment(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'record_payment_authorization_url(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated',
      'record_payment_authorization_url(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role',
      'record_payment_authorization_url(uuid,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'get_payment_authorization_url(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'get_payment_authorization_url(uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'get_payment_authorization_url(uuid)', 'EXECUTE')
    OR has_table_privilege('anon', 'payment_authorizations', 'SELECT')
    OR has_table_privilege('authenticated', 'payment_authorizations', 'SELECT') THEN
    RAISE EXCEPTION 'payment recovery function privileges are invalid';
  END IF;
END $$;

ROLLBACK;
