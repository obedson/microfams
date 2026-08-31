-- Platform-wide identity ownership binding with tenant-scoped KYC evidence.
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS platform_identity_bindings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_type TEXT NOT NULL CHECK (evidence_type IN ('nin', 'bvn')),
  identity_fingerprint VARCHAR(64) NOT NULL CHECK (identity_fingerprint ~ '^[a-f0-9]{64}$'),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  first_bound_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  verification_request_id UUID NOT NULL UNIQUE REFERENCES identity_verification_requests(id) ON DELETE RESTRICT,
  UNIQUE(evidence_type, identity_fingerprint),
  UNIQUE(user_id, evidence_type)
);

CREATE OR REPLACE FUNCTION protect_platform_identity_binding() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Platform identity bindings are append-only';
END;
$$;

DROP TRIGGER IF EXISTS platform_identity_bindings_append_only ON platform_identity_bindings;
CREATE TRIGGER platform_identity_bindings_append_only
  BEFORE UPDATE OR DELETE ON platform_identity_bindings
  FOR EACH ROW EXECUTE FUNCTION protect_platform_identity_binding();

ALTER TABLE platform_identity_bindings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON platform_identity_bindings FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON platform_identity_bindings FROM service_role;
GRANT SELECT ON platform_identity_bindings TO service_role;

ALTER TABLE financial_kyc_evidence
  ADD COLUMN IF NOT EXISTS consent_id UUID REFERENCES identity_consents(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS verification_request_id UUID REFERENCES identity_verification_requests(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS provider_environment TEXT CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  ADD COLUMN IF NOT EXISTS regulatory_context JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(regulatory_context) = 'object');
CREATE UNIQUE INDEX IF NOT EXISTS uq_financial_kyc_verification_request
  ON financial_kyc_evidence(verification_request_id)
  WHERE verification_request_id IS NOT NULL;

CREATE OR REPLACE FUNCTION complete_identity_verification(p_request_id UUID) RETURNS identity_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_request identity_verification_requests;
  v_bound_user UUID;
  v_user_fingerprint TEXT;
  v_consent_version TEXT;
BEGIN
  SELECT * INTO v_request
  FROM identity_verification_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'Active identity challenge not found';
  END IF;
  IF v_request.state = 'validated' THEN
    IF EXISTS (
      SELECT 1 FROM platform_identity_bindings
      WHERE evidence_type = v_request.evidence_type
        AND identity_fingerprint = v_request.identity_fingerprint
        AND user_id = v_request.user_id
    ) AND EXISTS (
      SELECT 1 FROM verified_identities
      WHERE verification_request_id = v_request.id
    ) THEN
      RETURN v_request;
    END IF;
    RAISE EXCEPTION 'Validated identity evidence is incomplete';
  END IF;
  IF v_request.state <> 'awaiting_otp' OR v_request.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Active identity challenge not found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'platform-identity:' || v_request.evidence_type || ':' || v_request.identity_fingerprint, 0));

  SELECT user_id INTO v_bound_user
  FROM platform_identity_bindings
  WHERE evidence_type = v_request.evidence_type
    AND identity_fingerprint = v_request.identity_fingerprint
  FOR UPDATE;
  IF v_bound_user IS NOT NULL AND v_bound_user <> v_request.user_id THEN
    RAISE EXCEPTION 'Identity is already bound to another user';
  END IF;

  SELECT identity_fingerprint INTO v_user_fingerprint
  FROM platform_identity_bindings
  WHERE user_id = v_request.user_id
    AND evidence_type = v_request.evidence_type
  FOR UPDATE;
  IF v_user_fingerprint IS NOT NULL
     AND v_user_fingerprint <> v_request.identity_fingerprint THEN
    RAISE EXCEPTION 'User is already bound to another identity of this type';
  END IF;

  IF v_bound_user IS NULL AND v_user_fingerprint IS NULL THEN
    INSERT INTO platform_identity_bindings(
      evidence_type, identity_fingerprint, user_id, verification_request_id
    ) VALUES (
      v_request.evidence_type, v_request.identity_fingerprint,
      v_request.user_id, v_request.id
    );
  END IF;

  INSERT INTO verified_identities(
    organization_id, user_id, evidence_type, identity_fingerprint, verification_request_id,
    provider_name, provider_reference, verified_at
  ) VALUES (
    v_request.organization_id, v_request.user_id, v_request.evidence_type,
    v_request.identity_fingerprint, v_request.id, v_request.provider_name,
    v_request.provider_reference, NOW()
  );

  SELECT consent_version INTO v_consent_version
  FROM identity_consents WHERE id = v_request.consent_id;
  INSERT INTO financial_kyc_evidence(
    organization_id, user_id, evidence_type, provider_name, provider_reference,
    status, validated_at, expires_at, recorded_by, consent_id,
    verification_request_id, provider_environment, regulatory_context
  ) VALUES (
    v_request.organization_id, v_request.user_id, v_request.evidence_type,
    v_request.provider_name, v_request.provider_reference, 'validated', NOW(), NULL,
    v_request.user_id, v_request.consent_id, v_request.id, v_request.provider_environment,
    jsonb_build_object(
      'jurisdiction', 'NG',
      'purpose', 'platform_identity_verification',
      'consent_version', v_consent_version
    )
  );

  UPDATE identity_verification_requests SET
    state = 'validated', validated_at = NOW(), challenge_token = NULL, updated_at = NOW()
  WHERE id = p_request_id RETURNING * INTO v_request;
  IF v_request.evidence_type = 'nin' THEN
    UPDATE users SET nin_verified = TRUE, updated_at = NOW()
    WHERE id = v_request.user_id;
  END IF;
  INSERT INTO identity_verification_events(organization_id, request_id, user_id, event_type)
  VALUES (v_request.organization_id, v_request.id, v_request.user_id, 'validated');
  RETURN v_request;
END;
$$;

REVOKE ALL ON FUNCTION complete_identity_verification(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_identity_verification(UUID)
  TO service_role;
