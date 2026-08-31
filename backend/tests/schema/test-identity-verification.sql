-- Identity verification lifecycle, evidence minimization, lockout and tenant isolation.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_user UUID := '00000000-0000-4000-8000-000000000101';
  v_fingerprint TEXT := repeat('b', 64);
  v_hash TEXT := repeat('c', 64);
  v_request identity_verification_requests;
  v_consent UUID;
  v_other_org UUID := '00000000-0000-4000-8000-000000000102';
  v_other_user UUID := '00000000-0000-4000-8000-000000000102';
  v_other_request identity_verification_requests;
  v_same_user_request identity_verification_requests;
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
  IF NOT EXISTS (
    SELECT 1 FROM platform_identity_bindings
    WHERE evidence_type = 'nin' AND identity_fingerprint = v_fingerprint
      AND user_id = v_user
  ) THEN RAISE EXCEPTION 'platform identity binding was not created'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM financial_kyc_evidence
    WHERE verification_request_id = v_request.id
      AND consent_id = v_request.consent_id
      AND provider_environment = 'deterministic'
      AND regulatory_context @> '{"jurisdiction":"NG","purpose":"platform_identity_verification","consent_version":"identity-v1"}'::JSONB
  ) THEN RAISE EXCEPTION 'tenant KYC evidence omitted governed context'; END IF;
  IF (complete_identity_verification(v_request.id)).id <> v_request.id THEN
    RAISE EXCEPTION 'identity completion is not idempotent';
  END IF;
  IF (SELECT count(*) FROM platform_identity_bindings
      WHERE evidence_type = 'nin' AND identity_fingerprint = v_fingerprint) <> 1
    OR (SELECT count(*) FROM verified_identities
        WHERE verification_request_id = v_request.id) <> 1 THEN
    RAISE EXCEPTION 'identity completion replay duplicated evidence';
  END IF;

  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES (v_other_org, v_user, 'member', 'active', NOW())
  ON CONFLICT DO NOTHING;

  v_other_request := start_identity_verification(
    v_other_org, v_other_user, 'nin', v_fingerprint, 'identity-schema-conflict',
    repeat('e', 64), 'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
  );
  v_other_request := mark_identity_challenge_sent(
    v_other_request.id, 'provider-reference-conflict', '0804****222', 'opaque-token-conflict'
  );
  BEGIN
    PERFORM complete_identity_verification(v_other_request.id);
    RAISE EXCEPTION 'platform binding accepted a different user';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%already bound to another user%' THEN RAISE; END IF;
  END;
  IF (SELECT state FROM identity_verification_requests WHERE id = v_other_request.id) <> 'awaiting_otp'
     OR EXISTS (SELECT 1 FROM verified_identities WHERE verification_request_id = v_other_request.id)
     OR EXISTS (SELECT 1 FROM financial_kyc_evidence WHERE verification_request_id = v_other_request.id) THEN
    RAISE EXCEPTION 'identity binding conflict did not roll back atomically';
  END IF;

  v_same_user_request := start_identity_verification(
    v_other_org, v_user, 'nin', v_fingerprint, 'identity-schema-portable',
    repeat('f', 64), 'identity-v1', repeat('d', 64), 'deterministic', 'deterministic'
  );
  v_same_user_request := mark_identity_challenge_sent(
    v_same_user_request.id, 'provider-reference-portable', '0803****123', 'opaque-token-portable'
  );
  v_same_user_request := complete_identity_verification(v_same_user_request.id);
  IF NOT EXISTS (
    SELECT 1 FROM verified_identities
    WHERE organization_id = v_other_org AND user_id = v_user
      AND verification_request_id = v_same_user_request.id
  ) OR NOT EXISTS (
    SELECT 1 FROM financial_kyc_evidence
    WHERE organization_id = v_other_org AND user_id = v_user
      AND verification_request_id = v_same_user_request.id
  ) OR (SELECT count(*) FROM platform_identity_bindings
        WHERE evidence_type = 'nin' AND identity_fingerprint = v_fingerprint) <> 1 THEN
    RAISE EXCEPTION 'same-user cross-tenant verification did not preserve one platform binding';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN (
        'platform_identity_bindings', 'verified_identities',
        'identity_verification_requests', 'financial_kyc_evidence'
      )
      AND column_name IN ('identifier', 'nin_number', 'bvn_number')
  ) OR (SELECT nin_number FROM users WHERE id = v_user) IS NOT NULL THEN
    RAISE EXCEPTION 'raw identity storage remains in the governed evidence path';
  END IF;

  SELECT consent_id INTO v_consent FROM identity_verification_requests WHERE id = v_request.id;
  BEGIN
    UPDATE identity_consents SET consent_version = 'tampered' WHERE id = v_consent;
    RAISE EXCEPTION 'consent evidence was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%immutable%' THEN RAISE; END IF;
  END;
END $$;


DO $$ BEGIN
  IF has_table_privilege('authenticated', 'platform_identity_bindings', 'INSERT')
     OR has_function_privilege('authenticated', 'complete_identity_verification(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'tenant clients can mutate platform identity bindings';
  END IF;
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
