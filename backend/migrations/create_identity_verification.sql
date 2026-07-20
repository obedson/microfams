-- Provider-neutral, tenant-isolated identity verification without raw identity storage.

CREATE TABLE identity_consents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL DEFAULT 'identity_verification',
  consent_version TEXT NOT NULL,
  consent_text_hash VARCHAR(64) NOT NULL CHECK (consent_text_hash ~ '^[a-f0-9]{64}$'),
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_identity_consents_subject
  ON identity_consents(organization_id, user_id, accepted_at DESC);

CREATE TABLE identity_verification_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  consent_id UUID NOT NULL REFERENCES identity_consents(id),
  evidence_type TEXT NOT NULL CHECK (evidence_type IN ('nin', 'bvn')),
  identity_fingerprint VARCHAR(64) NOT NULL CHECK (identity_fingerprint ~ '^[a-f0-9]{64}$'),
  provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_reference TEXT,
  masked_destination TEXT,
  challenge_token TEXT,
  state TEXT NOT NULL DEFAULT 'created' CHECK (state IN (
    'created', 'awaiting_otp', 'validated', 'rejected', 'failed', 'expired', 'cancelled'
  )),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  otp_attempts SMALLINT NOT NULL DEFAULT 0 CHECK (otp_attempts >= 0),
  maximum_otp_attempts SMALLINT NOT NULL DEFAULT 5 CHECK (maximum_otp_attempts BETWEEN 1 AND 10),
  failure_code TEXT,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '15 minutes'),
  validated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(organization_id, user_id, idempotency_key)
);
CREATE INDEX idx_identity_request_subject
  ON identity_verification_requests(organization_id, user_id, created_at DESC);
CREATE INDEX idx_identity_request_expiry
  ON identity_verification_requests(state, expires_at)
  WHERE state IN ('created', 'awaiting_otp');

CREATE UNIQUE INDEX uq_identity_provider_reference
  ON identity_verification_requests(provider_name, provider_environment, provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE TABLE verified_identities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  evidence_type TEXT NOT NULL CHECK (evidence_type IN ('nin', 'bvn')),
  identity_fingerprint VARCHAR(64) NOT NULL CHECK (identity_fingerprint ~ '^[a-f0-9]{64}$'),
  verification_request_id UUID NOT NULL UNIQUE REFERENCES identity_verification_requests(id),
  provider_name TEXT NOT NULL,
  provider_reference TEXT NOT NULL,
  verified_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  revocation_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(organization_id, evidence_type, identity_fingerprint),
  UNIQUE(organization_id, user_id, evidence_type)
);
ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_nin_verified_has_number;
CREATE OR REPLACE FUNCTION enforce_nin_verification_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.nin_verified AND NEW.nin_number IS NULL AND NOT EXISTS (
    SELECT 1 FROM verified_identities
    WHERE user_id = NEW.id AND evidence_type = 'nin' AND revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'NIN verification requires validated evidence';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER users_nin_verification_evidence
  BEFORE INSERT OR UPDATE OF nin_verified, nin_number ON users
  FOR EACH ROW EXECUTE FUNCTION enforce_nin_verification_evidence();


CREATE TABLE identity_verification_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  request_id UUID NOT NULL REFERENCES identity_verification_requests(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'created', 'challenge_sent', 'otp_failed', 'validated', 'failed', 'expired', 'cancelled'
  )),
  reason_code TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_identity_events_request
  ON identity_verification_events(organization_id, request_id, occurred_at);

CREATE OR REPLACE FUNCTION protect_identity_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Identity evidence and audit events are append-only';
END;
$$;
CREATE OR REPLACE FUNCTION protect_identity_consent() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
    AND (to_jsonb(OLD) - 'revoked_at') = (to_jsonb(NEW) - 'revoked_at') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Identity consent evidence is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION protect_verified_identity() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
    AND (to_jsonb(OLD) - 'revoked_at' - 'revocation_reason')
      = (to_jsonb(NEW) - 'revoked_at' - 'revocation_reason') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Verified identity evidence is immutable';
END;
$$;

CREATE TRIGGER identity_consents_append_only
  BEFORE UPDATE OR DELETE ON identity_consents FOR EACH ROW EXECUTE FUNCTION protect_identity_consent();
CREATE TRIGGER identity_events_append_only
  BEFORE UPDATE OR DELETE ON identity_verification_events FOR EACH ROW EXECUTE FUNCTION protect_identity_evidence();
CREATE TRIGGER verified_identities_append_only
  BEFORE UPDATE OR DELETE ON verified_identities FOR EACH ROW EXECUTE FUNCTION protect_verified_identity();

CREATE OR REPLACE FUNCTION start_identity_verification(
  p_organization_id UUID, p_user_id UUID, p_evidence_type TEXT,
  p_identity_fingerprint TEXT, p_idempotency_key TEXT, p_request_hash TEXT,
  p_consent_version TEXT, p_consent_text_hash TEXT,
  p_provider_name TEXT, p_provider_environment TEXT
) RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing identity_verification_requests;
  v_consent UUID;
  v_request identity_verification_requests;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_user_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'User is not an active organization member'; END IF;
  IF p_evidence_type NOT IN ('nin', 'bvn') THEN RAISE EXCEPTION 'Unsupported identity evidence type'; END IF;
  IF p_identity_fingerprint !~ '^[a-f0-9]{64}$' OR p_request_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'Identity request fingerprint is invalid';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':' || p_user_id::TEXT || ':' || p_idempotency_key, 0));
  SELECT * INTO v_existing FROM identity_verification_requests
  WHERE organization_id = p_organization_id AND user_id = p_user_id
    AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'Identity idempotency key reused with different facts';
    END IF;
    RETURN v_existing;
  END IF;
  IF EXISTS (
    SELECT 1 FROM verified_identities
    WHERE organization_id = p_organization_id AND evidence_type = p_evidence_type
      AND identity_fingerprint = p_identity_fingerprint AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'Identity is already verified'; END IF;

  INSERT INTO identity_consents(
    organization_id, user_id, consent_version, consent_text_hash
  ) VALUES (
    p_organization_id, p_user_id, p_consent_version, p_consent_text_hash
  ) RETURNING id INTO v_consent;
  INSERT INTO identity_verification_requests(
    organization_id, user_id, consent_id, evidence_type, identity_fingerprint,
    provider_name, provider_environment, idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_user_id, v_consent, p_evidence_type, p_identity_fingerprint,
    p_provider_name, p_provider_environment, p_idempotency_key, p_request_hash
  ) RETURNING * INTO v_request;
  INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type)
  VALUES (p_organization_id, v_request.id, p_user_id, 'created');
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION mark_identity_challenge_sent(
  p_request_id UUID, p_provider_reference TEXT, p_masked_destination TEXT, p_challenge_token TEXT
) RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request identity_verification_requests;
BEGIN
  SELECT * INTO v_request FROM identity_verification_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL THEN RAISE EXCEPTION 'Identity request not found'; END IF;
  IF v_request.state = 'awaiting_otp' THEN RETURN v_request; END IF;
  IF v_request.state <> 'created' OR v_request.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Identity request cannot accept a challenge';
  END IF;
  UPDATE identity_verification_requests SET
    state = 'awaiting_otp', provider_reference = p_provider_reference,
    masked_destination = p_masked_destination, challenge_token = p_challenge_token, updated_at = NOW()
  WHERE id = p_request_id RETURNING * INTO v_request;
  INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type)
  VALUES (v_request.organization_id, v_request.id, v_request.user_id, 'challenge_sent');
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION get_identity_verification_for_confirmation(
  p_request_id UUID, p_organization_id UUID, p_user_id UUID
) RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request identity_verification_requests;
BEGIN
  SELECT * INTO v_request FROM identity_verification_requests
  WHERE id = p_request_id AND organization_id = p_organization_id AND user_id = p_user_id;
  IF v_request.id IS NULL OR v_request.state <> 'awaiting_otp' OR v_request.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Active identity challenge not found';
  END IF;
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION record_identity_otp_failure(p_request_id UUID)
RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request identity_verification_requests;
BEGIN
  UPDATE identity_verification_requests SET
    otp_attempts = otp_attempts + 1,
    state = CASE WHEN otp_attempts + 1 >= maximum_otp_attempts THEN 'rejected' ELSE state END,
    failure_code = CASE WHEN otp_attempts + 1 >= maximum_otp_attempts THEN 'OTP_ATTEMPTS_EXHAUSTED' ELSE 'OTP_INVALID' END,
    updated_at = NOW()
  WHERE id = p_request_id AND state = 'awaiting_otp' AND expires_at > NOW()
  RETURNING * INTO v_request;
  IF v_request.id IS NULL THEN RAISE EXCEPTION 'Active identity challenge not found'; END IF;
  INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type, reason_code)
  VALUES (v_request.organization_id, v_request.id, v_request.user_id, 'otp_failed', v_request.failure_code);
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION fail_identity_verification(p_request_id UUID, p_reason_code TEXT)
RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request identity_verification_requests;
BEGIN
  UPDATE identity_verification_requests SET state = 'failed', failure_code = p_reason_code, updated_at = NOW()
  WHERE id = p_request_id AND state IN ('created', 'awaiting_otp')
  RETURNING * INTO v_request;
  IF v_request.id IS NOT NULL THEN
    INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type, reason_code)
    VALUES (v_request.organization_id, v_request.id, v_request.user_id, 'failed', p_reason_code);
  END IF;
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION complete_identity_verification(p_request_id UUID) RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request identity_verification_requests;
BEGIN
  SELECT * INTO v_request FROM identity_verification_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL OR v_request.state <> 'awaiting_otp' OR v_request.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Active identity challenge not found';
  END IF;
  INSERT INTO verified_identities(
    organization_id, user_id, evidence_type, identity_fingerprint, verification_request_id,
    provider_name, provider_reference, verified_at
  ) VALUES (
    v_request.organization_id, v_request.user_id, v_request.evidence_type,
    v_request.identity_fingerprint, v_request.id, v_request.provider_name,
    v_request.provider_reference, NOW()
  );
  INSERT INTO financial_kyc_evidence(
    organization_id, user_id, evidence_type, provider_name, provider_reference,
    status, validated_at, recorded_by
  ) VALUES (
    v_request.organization_id, v_request.user_id, v_request.evidence_type,
    v_request.provider_name, v_request.provider_reference, 'validated', NOW(), v_request.user_id
  );
  UPDATE identity_verification_requests SET
    state = 'validated', validated_at = NOW(), challenge_token = NULL, updated_at = NOW()
  WHERE id = p_request_id RETURNING * INTO v_request;
  IF v_request.evidence_type = 'nin' THEN
    UPDATE users SET nin_verified = TRUE, updated_at = NOW() WHERE id = v_request.user_id;
  END IF;
  INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type)
  VALUES (v_request.organization_id, v_request.id, v_request.user_id, 'validated');
  RETURN v_request;
END;
$$;

ALTER TABLE identity_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_verification_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE verified_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_verification_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY subject_read ON identity_consents FOR SELECT USING (user_id = auth.uid() AND has_active_organization_membership(organization_id));
CREATE POLICY subject_read ON identity_verification_requests FOR SELECT USING (user_id = auth.uid() AND has_active_organization_membership(organization_id));
CREATE POLICY subject_read ON verified_identities FOR SELECT USING (user_id = auth.uid() AND has_active_organization_membership(organization_id));
CREATE POLICY subject_read ON identity_verification_events FOR SELECT USING (user_id = auth.uid() AND has_active_organization_membership(organization_id));

REVOKE ALL ON identity_consents, identity_verification_requests, verified_identities,
  identity_verification_events FROM anon, authenticated;
REVOKE ALL ON FUNCTION
  start_identity_verification(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
  mark_identity_challenge_sent(UUID, TEXT, TEXT, TEXT),
  get_identity_verification_for_confirmation(UUID, UUID, UUID),
  record_identity_otp_failure(UUID),
  fail_identity_verification(UUID, TEXT),
  complete_identity_verification(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  start_identity_verification(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
  mark_identity_challenge_sent(UUID, TEXT, TEXT, TEXT),
  get_identity_verification_for_confirmation(UUID, UUID, UUID),
  record_identity_otp_failure(UUID),
  fail_identity_verification(UUID, TEXT),
  complete_identity_verification(UUID)
  TO service_role;
