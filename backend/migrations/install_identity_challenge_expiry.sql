-- Durable, replay-safe expiry servicing for provider identity challenges.
SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION expire_identity_verification_challenges(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_expired INTEGER;
BEGIN
  IF p_limit < 1 OR p_limit > 500 THEN
    RAISE EXCEPTION 'Identity challenge expiry limit must be between 1 and 500';
  END IF;

  WITH candidates AS (
    SELECT request.id
    FROM identity_verification_requests request
    WHERE request.state IN ('created', 'awaiting_otp')
      AND request.expires_at <= p_now
    ORDER BY request.expires_at, request.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ),
  expired AS (
    UPDATE identity_verification_requests request
    SET state = 'expired',
        challenge_token = NULL,
        failure_code = 'CHALLENGE_EXPIRED',
        updated_at = p_now
    FROM candidates
    WHERE request.id = candidates.id
    RETURNING request.id, request.organization_id, request.user_id
  ),
  events AS (
    INSERT INTO identity_verification_events(
      organization_id, request_id, user_id, event_type, reason_code, occurred_at
    )
    SELECT organization_id, id, user_id, 'expired', 'CHALLENGE_EXPIRED', p_now
    FROM expired
    RETURNING request_id
  )
  SELECT count(*)::INTEGER INTO v_expired FROM expired;

  RETURN v_expired;
END;
$$;

REVOKE ALL ON FUNCTION expire_identity_verification_challenges(INTEGER, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION expire_identity_verification_challenges(INTEGER, TIMESTAMPTZ)
  TO service_role;
