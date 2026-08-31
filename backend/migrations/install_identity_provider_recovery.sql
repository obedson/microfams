-- Provider-neutral degraded-provider evidence and confirmation retry support.
SET search_path = public, extensions;

ALTER TABLE identity_verification_events
  DROP CONSTRAINT IF EXISTS identity_verification_events_event_type_check;
ALTER TABLE identity_verification_events
  ADD CONSTRAINT identity_verification_events_event_type_check
  CHECK (event_type IN (
    'created', 'challenge_sent', 'otp_failed', 'validated', 'failed',
    'expired', 'cancelled', 'provider_deferred'
  ));

CREATE OR REPLACE FUNCTION record_identity_provider_deferred(p_request_id UUID)
RETURNS identity_verification_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_request identity_verification_requests;
BEGIN
  SELECT * INTO v_request
  FROM identity_verification_requests
  WHERE id = p_request_id
    AND state = 'awaiting_otp'
    AND expires_at > NOW()
  FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'Active identity challenge not found';
  END IF;

  UPDATE identity_verification_requests
  SET updated_at = NOW()
  WHERE id = v_request.id
  RETURNING * INTO v_request;

  INSERT INTO identity_verification_events(
    organization_id, request_id, user_id, event_type, reason_code
  ) VALUES (
    v_request.organization_id, v_request.id, v_request.user_id,
    'provider_deferred', 'PROVIDER_CONFIRM_UNAVAILABLE'
  );

  RETURN v_request;
END;
$$;

REVOKE ALL ON FUNCTION record_identity_provider_deferred(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION record_identity_provider_deferred(UUID)
  TO service_role;
