-- Identity verification lifecycle, evidence minimization, lockout and tenant isolation.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_user UUID := '00000000-0000-4000-8000-000000000101';
  v_fingerprint TEXT := repeat('b', 64);
  v_hash TEXT := repeat('c', 64);
  v_request identity_verification_requests;
  v_consent UUID;
BEGIN
  v_request := start_identity_verification(
    v_org, v_user, 'nin', v_fingerprint, 'identity-schema-1', v_hash,
    'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
  );
  IF v_request.state <> 'created' THEN RAISE EXCEPTION 'identity request was not created'; END IF;
  IF EXISTS (
    SELECT 1 FROM identity_verification_requests
    WHERE id = v_request.id AND to_jsonb(identity_verification_requests)::TEXT LIKE '%12345678901%'
  ) THEN RAISE EXCEPTION 'raw identity number was persisted'; END IF;

  IF (start_identity_verification(
    v_org, v_user, 'nin', v_fingerprint, 'identity-schema-1', v_hash,
    'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
  )).id <> v_request.id THEN RAISE EXCEPTION 'identity start is not idempotent'; END IF;

  BEGIN
    PERFORM start_identity_verification(
      v_org, v_user, 'nin', v_fingerprint, 'identity-schema-1', repeat('e', 64),
      'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
    );
    RAISE EXCEPTION 'identity idempotency accepted different facts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%different facts%' THEN RAISE; END IF;
  END;

  v_request := mark_identity_challenge_sent(v_request.id, 'provider-reference', '0803****123', 'opaque-token');
  IF v_request.state <> 'awaiting_otp' OR v_request.masked_destination <> '0803****123' THEN
    RAISE EXCEPTION 'identity challenge was not recorded safely';
  END IF;
  v_request := complete_identity_verification(v_request.id);
  IF v_request.state <> 'validated' OR v_request.challenge_token IS NOT NULL THEN
    RAISE EXCEPTION 'identity request was not completed safely';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM verified_identities
    WHERE organization_id = v_org AND user_id = v_user AND identity_fingerprint = v_fingerprint
  ) OR NOT EXISTS (
    SELECT 1 FROM financial_kyc_evidence
    WHERE organization_id = v_org AND user_id = v_user AND evidence_type = 'nin' AND status = 'validated'
  ) THEN RAISE EXCEPTION 'validated identity evidence was not linked to financial KYC'; END IF;
  IF NOT (SELECT nin_verified FROM users WHERE id = v_user)
    OR (SELECT nin_number FROM users WHERE id = v_user) IS NOT NULL THEN
    RAISE EXCEPTION 'legacy compatibility flag was not derived without raw NIN storage';
  END IF;

  SELECT consent_id INTO v_consent FROM identity_verification_requests WHERE id = v_request.id;
  BEGIN
    UPDATE identity_consents SET consent_version = 'tampered' WHERE id = v_consent;
    RAISE EXCEPTION 'consent evidence was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%immutable%' THEN RAISE; END IF;
  END;
END $$;

INSERT INTO users(id, email, password, name, role)
VALUES ('00000000-0000-4000-8000-000000000107', 'identity-outsider@example.test',
  'not-a-real-password', 'Identity Outsider', 'farmer');
GRANT SELECT ON identity_consents, identity_verification_requests,
  verified_identities, identity_verification_events TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000107', FALSE);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM identity_consents)
    OR EXISTS (SELECT 1 FROM identity_verification_requests)
    OR EXISTS (SELECT 1 FROM verified_identities)
    OR EXISTS (SELECT 1 FROM identity_verification_events) THEN
INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
VALUES ('00000000-0000-4000-8000-000000000101',
  '00000000-0000-4000-8000-000000000107', 'member', 'active', NOW());
    RAISE EXCEPTION 'identity verification data leaked to another tenant member';
  END IF;
END $$;
RESET ROLE;
