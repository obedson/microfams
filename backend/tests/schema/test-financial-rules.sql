-- FC-07 policy lifecycle, decision snapshots, risk controls and tenant isolation.
DO $$
DECLARE
  v_org UUID := '00000000-0000-4000-8000-000000000101';
  v_maker UUID := '00000000-0000-4000-8000-000000000105';
  v_checker UUID := '00000000-0000-4000-8000-000000000101';
  v_rule UUID;
  v_request UUID;
  v_decision JSONB;
  v_control UUID;
  v_activation UUID;
BEGIN
  INSERT INTO users(id, email, password, name, role)
  VALUES (v_maker, 'rule-maker@example.test', 'not-a-real-password', 'Rule Maker', 'farmer')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO organization_memberships(organization_id, user_id, role, permissions, status, joined_at)
  VALUES (v_org, v_maker, 'finance_manager', ARRAY['financial.rules.propose', 'financial.activation.manage'], 'active', NOW())
  ON CONFLICT (organization_id, user_id) DO UPDATE
    SET permissions = EXCLUDED.permissions, status = 'active';

  INSERT INTO financial_rule_versions(
    organization_id, rule_code, version, jurisdiction, product, channel, currency,
    minimum_kyc_tier, effective_from, change_reason, created_by
  ) VALUES (
    v_org, 'wallet.p2p.standard', 1, 'NG', 'wallet', 'p2p', 'NGN',
    0, NOW() - INTERVAL '1 minute', 'Schema test tenant policy', v_maker
  ) RETURNING id INTO v_rule;
  INSERT INTO financial_rule_limits(
    rule_version_id, dimension, minimum_minor, maximum_minor,
    provider_regulatory_ceiling_minor, period_seconds
  ) VALUES (v_rule, 'rolling_period', 10000, 1000000, 2000000, 86400);

  v_request := submit_financial_rule(v_rule, v_maker);
  BEGIN
    PERFORM decide_financial_rule(v_request, v_maker, TRUE, 'self approval');
    RAISE EXCEPTION 'maker-checker accepted the same actor';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%Maker cannot approve%' THEN RAISE; END IF;
  END;
  PERFORM decide_financial_rule(v_request, v_checker, TRUE, 'independent approval');

  BEGIN
    UPDATE financial_rule_versions SET change_reason = 'tampered' WHERE id = v_rule;
    RAISE EXCEPTION 'active rule was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%immutable%' THEN RAISE; END IF;
  END;

  v_decision := enforce_financial_command(
    v_org, v_maker, 'wallet.p2p', 'schema-command-1', 'wallet', 'p2p', 'NGN', 500000, 'NG'
  );
  IF NOT (v_decision->>'approved')::BOOLEAN OR (v_decision->>'rule_version')::INTEGER <> 1 THEN
    RAISE EXCEPTION 'eligible command was not approved with its rule version: %', v_decision;
  END IF;
  IF (enforce_financial_command(
    v_org, v_maker, 'wallet.p2p', 'schema-command-1', 'wallet', 'p2p', 'NGN', 500000, 'NG'
  )->>'snapshot_id') <> (v_decision->>'snapshot_id') THEN
    RAISE EXCEPTION 'compliance decision is not idempotent';
  END IF;
  BEGIN
    PERFORM enforce_financial_command(
      v_org, v_maker, 'wallet.p2p', 'schema-command-1', 'wallet', 'p2p', 'NGN', 500001, 'NG'
    );
    RAISE EXCEPTION 'idempotency key accepted changed financial facts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%different facts%' THEN RAISE; END IF;
  END;

  v_decision := enforce_financial_command(
    v_org, v_maker, 'wallet.p2p', 'schema-command-2', 'wallet', 'p2p', 'NGN', 600000, 'NG'
  );
  IF (v_decision->>'approved')::BOOLEAN OR NOT ('rolling_period_maximum' = ANY(
    ARRAY(SELECT jsonb_array_elements_text(v_decision->'reasons'))
  )) THEN RAISE EXCEPTION 'rolling limit did not deny the command: %', v_decision; END IF;

  v_control := place_financial_risk_control(
    v_org, v_checker, 'freeze', 'user', v_maker::TEXT, 'wallet',
    'SCHEMA_RISK', 'Schema risk test'
  );
  v_decision := enforce_financial_command(
    v_org, v_maker, 'wallet.p2p', 'schema-command-3', 'wallet', 'p2p', 'NGN', 10000, 'NG'
  );
  IF (v_decision->>'approved')::BOOLEAN OR NOT ('risk_control_active' = ANY(
    ARRAY(SELECT jsonb_array_elements_text(v_decision->'reasons'))
  )) THEN RAISE EXCEPTION 'risk control did not block new exposure: %', v_decision; END IF;
  PERFORM release_financial_risk_control(v_control, v_checker, 'Schema risk cleared');

  v_activation := request_financial_live_activation(
    v_org, v_maker, 'payments', 'NG', 'Licensed Test Provider', v_checker,
    'evidence-reference', 'kyc-rules-reference', 'regulatory-source',
    CURRENT_DATE, NOW()
  );
  BEGIN
    PERFORM decide_financial_live_activation(v_activation, v_maker, TRUE, 'self approval');
    RAISE EXCEPTION 'live activation accepted maker self-approval';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%Maker cannot approve%' THEN RAISE; END IF;
  END;
  PERFORM decide_financial_live_activation(v_activation, v_checker, TRUE, 'independent approval');
END $$;

INSERT INTO users(id, email, password, name, role)
VALUES ('00000000-0000-4000-8000-000000000106', 'financial-outsider@example.test',
  'not-a-real-password', 'Financial Outsider', 'farmer');
GRANT SELECT ON financial_rule_versions, financial_rule_limits,
  financial_approval_requests, financial_risk_controls, financial_compliance_snapshots TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000106', FALSE);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM financial_rule_versions WHERE organization_id IS NOT NULL) THEN
    RAISE EXCEPTION 'financial rule data leaked across tenants';
  END IF;
  IF EXISTS (SELECT 1 FROM financial_compliance_snapshots) THEN
    RAISE EXCEPTION 'financial decision data leaked across tenants';
  END IF;
  IF EXISTS (SELECT 1 FROM financial_risk_controls) THEN
    RAISE EXCEPTION 'financial risk data leaked across tenants';
  END IF;
END $$;
RESET ROLE;
