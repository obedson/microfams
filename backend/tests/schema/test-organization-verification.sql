-- Organization verification idempotency, evidence minimization, authorization and isolation.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_owner UUID := '00000000-0000-4000-8000-000000000101';
  v_request organization_verification_requests;
  v_attestation UUID;
  v_other organization_verification_requests;
BEGIN
  v_request := start_organization_verification(
    v_org, v_owner, 'cac_rc', repeat('1', 64), 'RC/****4567',
    'organization-v1', repeat('2', 64), 'deterministic', 'deterministic',
    'organization-schema-1', repeat('3', 64)
  );
  IF v_request.state <> 'created' THEN
    RAISE EXCEPTION 'organization verification request was not created';
  END IF;
  IF to_jsonb(v_request)::TEXT LIKE '%RC/1234567%' THEN
    RAISE EXCEPTION 'raw organization registration number was persisted';
  END IF;

  IF (start_organization_verification(
    v_org, v_owner, 'cac_rc', repeat('1', 64), 'RC/****4567',
    'organization-v1', repeat('2', 64), 'deterministic', 'deterministic',
    'organization-schema-1', repeat('3', 64)
  )).id <> v_request.id THEN
    RAISE EXCEPTION 'organization verification start is not idempotent';
  END IF;

  BEGIN
    PERFORM start_organization_verification(
      v_org, v_owner, 'cac_rc', repeat('1', 64), 'RC/****4567',
      'organization-v1', repeat('2', 64), 'deterministic', 'deterministic',
      'organization-schema-1', repeat('4', 64)
    );
    RAISE EXCEPTION 'organization idempotency accepted changed facts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%different facts%' THEN RAISE; END IF;
  END;

  v_other := start_organization_verification(
    '00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000102', 'other', repeat('8', 64), 'AL/****0001',
    'organization-v1', repeat('2', 64), 'deterministic', 'deterministic',
    'organization-schema-other', repeat('9', 64)
  );
  BEGIN
    PERFORM complete_organization_verification(
      v_other.id, 'provider-other-reference', 'verified', repeat('a', 64), NULL
    );
    RAISE EXCEPTION 'alternative evidence was automatically verified';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requires manual review%' THEN RAISE; END IF;
  END;

  v_request := complete_organization_verification(
    v_request.id, 'provider-org-reference', 'verified', repeat('5', 64), NULL
  );
  IF v_request.state <> 'verified' OR v_request.provider_evidence_hash <> repeat('5', 64) THEN
    RAISE EXCEPTION 'organization verification result was not completed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM verified_organizations
    WHERE organization_id = v_org
      AND registration_fingerprint = repeat('1', 64)
      AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'verified organization evidence was not created'; END IF;

  SELECT attestation_id INTO v_attestation
  FROM organization_verification_requests WHERE id = v_request.id;
  BEGIN
    UPDATE organization_verification_attestations
    SET attestation_version = 'tampered'
    WHERE id = v_attestation;
    RAISE EXCEPTION 'organization attestation was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%immutable%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM start_organization_verification(
      v_org, '00000000-0000-4000-8000-000000000107',
      'cac_rc', repeat('6', 64), 'RC/****9999',
      'organization-v1', repeat('2', 64), 'deterministic', 'deterministic',
      'organization-schema-member', repeat('7', 64)
    );
    RAISE EXCEPTION 'ordinary member submitted organization verification';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%owner or administrator%' THEN RAISE; END IF;
  END;

  IF (get_organization_verification_status(v_org, v_owner)).id <> v_request.id THEN
    RAISE EXCEPTION 'organization verification status lookup failed';
  END IF;
END $$;

INSERT INTO users(id, email, password, name, role)
VALUES ('00000000-0000-4000-8000-000000000109', 'organization-outsider@example.test',
  'not-a-real-password', 'Organization Outsider', 'farmer');
GRANT SELECT ON organization_verification_attestations, organization_verification_requests,
  verified_organizations, organization_verification_events TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000109', FALSE);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM organization_verification_attestations)
    OR EXISTS (SELECT 1 FROM organization_verification_requests)
    OR EXISTS (SELECT 1 FROM verified_organizations)
    OR EXISTS (SELECT 1 FROM organization_verification_events) THEN
    RAISE EXCEPTION 'organization verification evidence leaked across tenants';
  END IF;
END $$;
RESET ROLE;
