-- Durable identity challenge expiry, replay safety, redaction, and authorization.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_user UUID := '00000000-0000-4000-8000-000000000101';
  v_now TIMESTAMPTZ := '2026-08-31T15:00:00Z';
  v_created identity_verification_requests;
  v_awaiting identity_verification_requests;
  v_future identity_verification_requests;
  v_failed identity_verification_requests;
  v_rejected identity_verification_requests;
  v_replacement identity_verification_requests;
  v_validated_id UUID;
BEGIN
  v_created := start_identity_verification(
    v_org, v_user, 'bvn', repeat('1', 64), 'identity-expiry-created',
    repeat('a', 64), 'identity-v1', repeat('b', 64), 'deterministic', 'deterministic'
  );
  UPDATE identity_verification_requests
  SET expires_at = v_now - INTERVAL '1 minute'
  WHERE id = v_created.id;

  v_awaiting := start_identity_verification(
    v_org, v_user, 'bvn', repeat('2', 64), 'identity-expiry-awaiting',
    repeat('c', 64), 'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
  );
  v_awaiting := mark_identity_challenge_sent(
    v_awaiting.id, 'expiry-provider-awaiting', '0803****123', 'encrypted-expiry-state'
  );
  UPDATE identity_verification_requests
  SET expires_at = v_now - INTERVAL '1 second'
  WHERE id = v_awaiting.id;

  v_future := start_identity_verification(
    v_org, v_user, 'bvn', repeat('3', 64), 'identity-expiry-future',
    repeat('e', 64), 'identity-v1', repeat('f', 64), 'deterministic', 'deterministic'
  );
  v_future := mark_identity_challenge_sent(
    v_future.id, 'expiry-provider-future', '0803****123', 'future-encrypted-state'
  );
  UPDATE identity_verification_requests
  SET expires_at = v_now + INTERVAL '1 minute'
  WHERE id = v_future.id;

  v_failed := start_identity_verification(
    v_org, v_user, 'bvn', repeat('4', 64), 'identity-expiry-failed',
    repeat('1', 64), 'identity-v1', repeat('2', 64), 'deterministic', 'deterministic'
  );
  v_failed := mark_identity_challenge_sent(
    v_failed.id, 'expiry-provider-failed', '0803****123', 'failed-provider-state'
  );
  v_failed := fail_identity_verification(v_failed.id, 'PROVIDER_UNAVAILABLE');
  UPDATE identity_verification_requests
  SET expires_at = v_now - INTERVAL '1 minute'
  WHERE id = v_failed.id;

  v_rejected := start_identity_verification(
    v_org, v_user, 'bvn', repeat('5', 64), 'identity-expiry-rejected',
    repeat('3', 64), 'identity-v1', repeat('4', 64), 'deterministic', 'deterministic'
  );
  v_rejected := mark_identity_challenge_sent(
    v_rejected.id, 'expiry-provider-rejected', '0803****123', 'rejected-provider-state'
  );
  UPDATE identity_verification_requests
  SET state = 'rejected', failure_code = 'OTP_ATTEMPTS_EXHAUSTED',
      expires_at = v_now - INTERVAL '1 minute'
  WHERE id = v_rejected.id;

  SELECT id INTO v_validated_id
  FROM identity_verification_requests
  WHERE state = 'validated'
  ORDER BY created_at
  LIMIT 1;

  IF expire_identity_verification_challenges(100, v_now) <> 2 THEN
    RAISE EXCEPTION 'identity expiry did not service exactly the due active requests';
  END IF;
  IF EXISTS (
    SELECT 1 FROM identity_verification_requests
    WHERE id IN (v_created.id, v_awaiting.id)
      AND (state <> 'expired' OR challenge_token IS NOT NULL
        OR failure_code <> 'CHALLENGE_EXPIRED' OR updated_at <> v_now)
  ) THEN
    RAISE EXCEPTION 'identity expiry did not redact and transition due challenges';
  END IF;
  IF (SELECT state FROM identity_verification_requests WHERE id = v_future.id) <> 'awaiting_otp'
     OR (SELECT challenge_token FROM identity_verification_requests WHERE id = v_future.id)
        <> 'future-encrypted-state'
     OR (SELECT state FROM identity_verification_requests WHERE id = v_failed.id) <> 'failed'
     OR (SELECT state FROM identity_verification_requests WHERE id = v_rejected.id) <> 'rejected'
     OR (v_validated_id IS NOT NULL AND
       (SELECT state FROM identity_verification_requests WHERE id = v_validated_id) <> 'validated') THEN
    RAISE EXCEPTION 'identity expiry mutated a non-expired or terminal request';
  END IF;
  IF EXISTS (
    SELECT request_id
    FROM identity_verification_events
    WHERE request_id IN (v_created.id, v_awaiting.id)
      AND event_type = 'expired' AND reason_code = 'CHALLENGE_EXPIRED'
    GROUP BY request_id
    HAVING count(*) <> 1
  ) OR (
    SELECT count(*) FROM identity_verification_events
    WHERE request_id IN (v_created.id, v_awaiting.id)
      AND event_type = 'expired' AND reason_code = 'CHALLENGE_EXPIRED'
  ) <> 2 THEN
    RAISE EXCEPTION 'identity expiry did not append one event per request';
  END IF;
  IF expire_identity_verification_challenges(100, v_now) <> 0
     OR (SELECT count(*) FROM identity_verification_events
         WHERE request_id IN (v_created.id, v_awaiting.id)
           AND event_type = 'expired') <> 2 THEN
    RAISE EXCEPTION 'identity expiry replay duplicated servicing evidence';
  END IF;

  v_replacement := start_identity_verification(
    v_org, v_user, 'bvn', repeat('1', 64), 'identity-expiry-replacement',
    repeat('5', 64), 'identity-v1', repeat('6', 64), 'deterministic', 'deterministic'
  );
  IF v_replacement.state <> 'created' OR v_replacement.id = v_created.id THEN
    RAISE EXCEPTION 'expired identity request could not be retried with a new key';
  END IF;
END $$;

DO $$ BEGIN
  IF has_function_privilege(
    'authenticated',
    'expire_identity_verification_challenges(integer,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'tenant clients can execute identity expiry servicing';
  END IF;
END $$;
