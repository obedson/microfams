-- Provider-neutral, tenant-isolated organization verification without raw registration storage.

CREATE TABLE organization_verification_attestations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  attestation_version TEXT NOT NULL,
  attestation_text_hash VARCHAR(64) NOT NULL CHECK (attestation_text_hash ~ '^[a-f0-9]{64}$'),
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE organization_verification_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  submitted_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  attestation_id UUID NOT NULL REFERENCES organization_verification_attestations(id),
  registration_type TEXT NOT NULL CHECK (registration_type IN (
    'cac_rc', 'cac_bn', 'ngo_registration', 'government_program', 'other'
  )),
  registration_fingerprint VARCHAR(64) NOT NULL CHECK (registration_fingerprint ~ '^[a-f0-9]{64}$'),
  masked_registration TEXT NOT NULL CHECK (length(masked_registration) BETWEEN 2 AND 64 AND position('*' IN masked_registration) > 0),
  provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_reference TEXT,
  provider_evidence_hash VARCHAR(64) CHECK (
    provider_evidence_hash IS NULL OR provider_evidence_hash ~ '^[a-f0-9]{64}$'
  ),
  state TEXT NOT NULL DEFAULT 'created' CHECK (state IN (
    'created', 'verified', 'review_required', 'rejected', 'failed', 'cancelled'
  )),
  reason_code TEXT,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(organization_id, idempotency_key)
);
CREATE INDEX idx_organization_verification_requests
  ON organization_verification_requests(organization_id, created_at DESC);
CREATE UNIQUE INDEX uq_organization_verification_provider_reference
  ON organization_verification_requests(provider_name, provider_environment, provider_reference)
  WHERE provider_reference IS NOT NULL;

CREATE UNIQUE INDEX uq_organization_verification_active
  ON organization_verification_requests(organization_id)
  WHERE state = 'created';
CREATE TABLE verified_organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL UNIQUE REFERENCES organizations(id) ON DELETE RESTRICT,
  registration_type TEXT NOT NULL CHECK (registration_type IN (
    'cac_rc', 'cac_bn', 'ngo_registration', 'government_program', 'other'
  )),
  jurisdiction CHAR(2) NOT NULL CHECK (jurisdiction = upper(jurisdiction)),
  registration_fingerprint VARCHAR(64) NOT NULL CHECK (registration_fingerprint ~ '^[a-f0-9]{64}$'),
  verification_request_id UUID NOT NULL UNIQUE REFERENCES organization_verification_requests(id),
  provider_name TEXT NOT NULL,
  provider_reference TEXT NOT NULL,
  verified_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  revocation_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(jurisdiction, registration_type, registration_fingerprint)
);

CREATE TABLE organization_verification_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  request_id UUID NOT NULL REFERENCES organization_verification_requests(id) ON DELETE CASCADE,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'created', 'verified', 'review_required', 'rejected', 'failed', 'cancelled', 'revoked'
  )),
  reason_code TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_organization_verification_events
  ON organization_verification_events(organization_id, request_id, occurred_at);

CREATE OR REPLACE FUNCTION protect_organization_verification_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Organization verification evidence is append-only';
END;
$$;

CREATE OR REPLACE FUNCTION protect_organization_attestation() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
    AND (to_jsonb(OLD) - 'revoked_at') = (to_jsonb(NEW) - 'revoked_at') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Organization verification attestation is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION protect_verified_organization() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
    AND (to_jsonb(OLD) - 'revoked_at' - 'revocation_reason')
      = (to_jsonb(NEW) - 'revoked_at' - 'revocation_reason') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Verified organization evidence is immutable';
END;
$$;

CREATE TRIGGER organization_attestations_append_only
  BEFORE UPDATE OR DELETE ON organization_verification_attestations
  FOR EACH ROW EXECUTE FUNCTION protect_organization_attestation();
CREATE TRIGGER organization_verification_events_append_only
  BEFORE UPDATE OR DELETE ON organization_verification_events
  FOR EACH ROW EXECUTE FUNCTION protect_organization_verification_evidence();
CREATE TRIGGER verified_organizations_append_only
  BEFORE UPDATE OR DELETE ON verified_organizations
  FOR EACH ROW EXECUTE FUNCTION protect_verified_organization();

CREATE OR REPLACE FUNCTION start_organization_verification(
  p_organization_id UUID,
  p_user_id UUID,
  p_registration_type TEXT,
  p_registration_fingerprint TEXT,
  p_masked_registration TEXT,
  p_attestation_version TEXT,
  p_attestation_text_hash TEXT,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_idempotency_key TEXT,
  p_request_hash TEXT
) RETURNS organization_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing organization_verification_requests;
  v_attestation_id UUID;
  v_request organization_verification_requests;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_user_id
      AND status = 'active'
      AND role IN ('owner', 'admin')
  ) THEN RAISE EXCEPTION 'Organization owner or administrator access is required'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organizations WHERE id = p_organization_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'Active organization not found'; END IF;
  IF p_registration_type NOT IN ('cac_rc', 'cac_bn', 'ngo_registration', 'government_program', 'other') THEN
    RAISE EXCEPTION 'Unsupported organization registration type';
  END IF;
  IF p_provider_environment NOT IN ('deterministic', 'sandbox', 'live') THEN
    RAISE EXCEPTION 'Unsupported organization verification environment';
  END IF;
  IF p_registration_fingerprint !~ '^[a-f0-9]{64}$'
    OR p_attestation_text_hash !~ '^[a-f0-9]{64}$'
    OR p_request_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'Organization verification fingerprint is invalid';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':' || p_idempotency_key, 0
  ));
  SELECT * INTO v_existing
  FROM organization_verification_requests
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'Organization verification idempotency key reused with different facts';
    END IF;
    RETURN v_existing;
  END IF;
  IF EXISTS (
    SELECT 1 FROM verified_organizations
    WHERE organization_id = p_organization_id AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'Organization is already verified'; END IF;
  IF EXISTS (
    SELECT 1 FROM organization_verification_requests
    WHERE organization_id = p_organization_id AND state = 'created'
  ) THEN RAISE EXCEPTION 'Organization already has an active verification request'; END IF;


  INSERT INTO organization_verification_attestations(
    organization_id, actor_id, attestation_version, attestation_text_hash
  ) VALUES (
    p_organization_id, p_user_id, p_attestation_version, p_attestation_text_hash
  ) RETURNING id INTO v_attestation_id;

  INSERT INTO organization_verification_requests(
    organization_id, submitted_by, attestation_id, registration_type,
    registration_fingerprint, masked_registration, provider_name, provider_environment,
    idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_user_id, v_attestation_id, p_registration_type,
    p_registration_fingerprint, p_masked_registration, p_provider_name,
    p_provider_environment, p_idempotency_key, p_request_hash
  ) RETURNING * INTO v_request;

  INSERT INTO organization_verification_events(
    organization_id, request_id, actor_id, event_type
  ) VALUES (p_organization_id, v_request.id, p_user_id, 'created');
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION complete_organization_verification(
  p_request_id UUID,
  p_provider_reference TEXT,
  p_outcome TEXT,
  p_evidence_hash TEXT,
  p_reason_code TEXT
) RETURNS organization_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_request organization_verification_requests;
  v_jurisdiction CHAR(2);
BEGIN
  SELECT * INTO v_request
  FROM organization_verification_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF v_request.id IS NULL OR v_request.state <> 'created' THEN
    RAISE EXCEPTION 'Organization verification request cannot be completed';
  END IF;
  IF p_outcome NOT IN ('verified', 'review_required', 'rejected') THEN
    RAISE EXCEPTION 'Unsupported organization verification outcome';
  END IF;
  IF NULLIF(trim(p_provider_reference), '') IS NULL
    OR p_evidence_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'Organization provider evidence is invalid';
  END IF;

  UPDATE organization_verification_requests SET
    provider_reference = p_provider_reference,
    provider_evidence_hash = p_evidence_hash,
    state = p_outcome,
    reason_code = p_reason_code,
    decided_at = NOW(),
    updated_at = NOW()
  WHERE id = p_request_id
  RETURNING * INTO v_request;

  IF p_outcome = 'verified' THEN
  IF v_request.registration_type = 'other' AND p_outcome = 'verified' THEN
    RAISE EXCEPTION 'Alternative organization evidence requires manual review';
  END IF;
    SELECT jurisdiction INTO v_jurisdiction FROM organizations WHERE id = v_request.organization_id;
    INSERT INTO verified_organizations(
      organization_id, registration_type, jurisdiction, registration_fingerprint,
      verification_request_id, provider_name, provider_reference, verified_at
    ) VALUES (
      v_request.organization_id, v_request.registration_type, v_jurisdiction,
      v_request.registration_fingerprint, v_request.id, v_request.provider_name,
      p_provider_reference, NOW()
    );
  END IF;

  INSERT INTO organization_verification_events(
    organization_id, request_id, actor_id, event_type, reason_code
  ) VALUES (
    v_request.organization_id, v_request.id, v_request.submitted_by, p_outcome, p_reason_code
  );
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION fail_organization_verification(
  p_request_id UUID,
  p_reason_code TEXT
) RETURNS organization_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request organization_verification_requests;
BEGIN
  UPDATE organization_verification_requests SET
    state = 'failed',
    reason_code = p_reason_code,
    decided_at = NOW(),
    updated_at = NOW()
  WHERE id = p_request_id AND state = 'created'
  RETURNING * INTO v_request;
  IF v_request.id IS NOT NULL THEN
    INSERT INTO organization_verification_events(
      organization_id, request_id, actor_id, event_type, reason_code
    ) VALUES (
      v_request.organization_id, v_request.id, v_request.submitted_by, 'failed', p_reason_code
    );
  END IF;
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION get_organization_verification_status(
  p_organization_id UUID,
  p_user_id UUID
) RETURNS organization_verification_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request organization_verification_requests;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_user_id
      AND status = 'active'
  ) THEN RAISE EXCEPTION 'Active organization membership is required'; END IF;

  SELECT * INTO v_request
  FROM organization_verification_requests
  WHERE organization_id = p_organization_id
  ORDER BY created_at DESC, id DESC
  LIMIT 1;
  RETURN v_request;
END;
$$;

ALTER TABLE organization_verification_attestations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_verification_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE verified_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_verification_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_read ON organization_verification_attestations
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON organization_verification_requests
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON verified_organizations
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON organization_verification_events
  FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON organization_verification_attestations, organization_verification_requests,
  verified_organizations, organization_verification_events FROM anon, authenticated;
REVOKE ALL ON FUNCTION
  start_organization_verification(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
  complete_organization_verification(UUID, TEXT, TEXT, TEXT, TEXT),
  fail_organization_verification(UUID, TEXT),
  get_organization_verification_status(UUID, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  start_organization_verification(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
  complete_organization_verification(UUID, TEXT, TEXT, TEXT, TEXT),
  fail_organization_verification(UUID, TEXT),
  get_organization_verification_status(UUID, UUID)
  TO service_role;
