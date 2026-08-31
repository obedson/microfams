-- Provider degradation keeps active challenges retryable and tenant clients locked out.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_user UUID := '00000000-0000-4000-8000-000000000101';
  v_request identity_verification_requests;
  v_deferred identity_verification_requests;
BEGIN
  v_request := start_identity_verification(
    v_org, v_user, 'bvn', repeat('7', 64), 'identity-provider-recovery',
    repeat('8', 64), 'identity-v1', repeat('9', 64), 'deterministic', 'deterministic'
  );
  v_request := mark_identity_challenge_sent(
    v_request.id, 'provider-recovery-reference', '0803****123', 'encrypted-retry-state'
  );

  v_deferred := record_identity_provider_deferred(v_request.id);
  IF v_deferred.state <> 'awaiting_otp'
     OR v_deferred.challenge_token <> 'encrypted-retry-state'
     OR v_deferred.otp_attempts <> 0
     OR v_deferred.failure_code IS NOT NULL THEN
    RAISE EXCEPTION 'provider deferral corrupted the retryable challenge';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM identity_verification_events
    WHERE request_id = v_request.id
      AND event_type = 'provider_deferred'
      AND reason_code = 'PROVIDER_CONFIRM_UNAVAILABLE'
  ) THEN
    RAISE EXCEPTION 'provider deferral omitted stable audit evidence';
  END IF;

  UPDATE identity_verification_requests
  SET expires_at = NOW() - INTERVAL '1 second'
  WHERE id = v_request.id;
  BEGIN
    PERFORM record_identity_provider_deferred(v_request.id);
    RAISE EXCEPTION 'expired identity challenge accepted provider deferral';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%Active identity challenge not found%' THEN RAISE; END IF;
  END;
END $$;

DO $$ BEGIN
  IF has_function_privilege(
    'authenticated', 'record_identity_provider_deferred(uuid)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'tenant clients can record provider deferrals';
  END IF;
END $$;
