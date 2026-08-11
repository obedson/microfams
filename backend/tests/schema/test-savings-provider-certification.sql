-- SAV-06 contract: provider evidence is tenant-scoped and append-only; the
-- latest complete scenario set must pass with zero unexplained variance;
-- certification and live activation require independent approval.
SET search_path=public,extensions;

DO $$
DECLARE
  org_id UUID:='00000000-0000-4000-8000-000000000101';
  maker_id UUID:='00000000-0000-4000-8000-000000000101';
  checker_id UUID; outsider_id UUID; sandbox_cert UUID; live_cert UUID; activation_id UUID;
  scenario_code TEXT; scenario_number INTEGER:=0; failed BOOLEAN:=FALSE; result JSONB;
  fingerprint TEXT:=repeat('a',64); evidence_hash TEXT:=repeat('b',64);
  now_at TIMESTAMPTZ:=TIMESTAMPTZ '2026-08-11 12:00:00+00';
  scenarios TEXT[]:=ARRAY[
    'contribution_success','contribution_duplicate','contribution_failure',
    'standing_order_retry','withdrawal_success','withdrawal_failure',
    'provider_callback_replay','reconciliation_zero_variance','servicing_after_disable'];
BEGIN
  INSERT INTO users(email,password,name,role) VALUES(
    'sav06-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test',
    'test','SAV06 Checker','admin') RETURNING id INTO checker_id;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
  VALUES(org_id,checker_id,'admin',ARRAY['financial.activation.manage'],'active',now_at);
  INSERT INTO users(email,password,name,role) VALUES(
    'sav06-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test',
    'test','SAV06 Outsider','farmer') RETURNING id INTO outsider_id;

  result:=create_savings_provider_certification(
    org_id,maker_id,'licensed.savings','Licensed Savings Provider Limited','sandbox','NG','NGN',1,
    fingerprint,'evidence/provider-contract','evidence/credential-validation','evidence/webhook-certification',
    'evidence/settlement-account','evidence/compliance-notes','evidence/threat-model','evidence/privacy-review',
    'evidence/support-runbook','evidence/reconciliation-signoff','evidence/limits-disclosures',maker_id,
    now_at+INTERVAL '1 year','sav06-create-sandbox-001',now_at);
  sandbox_cert:=(result->>'id')::UUID;
  IF sandbox_cert IS NULL THEN RAISE EXCEPTION 'SAV06: sandbox certification was not created'; END IF;
  IF (create_savings_provider_certification(
    org_id,maker_id,'licensed.savings','Licensed Savings Provider Limited','sandbox','NG','NGN',1,
    fingerprint,'evidence/provider-contract','evidence/credential-validation','evidence/webhook-certification',
    'evidence/settlement-account','evidence/compliance-notes','evidence/threat-model','evidence/privacy-review',
    'evidence/support-runbook','evidence/reconciliation-signoff','evidence/limits-disclosures',maker_id,
    now_at+INTERVAL '1 year','sav06-create-sandbox-001',now_at)->>'id')::UUID<>sandbox_cert
  THEN RAISE EXCEPTION 'SAV06: creation idempotency did not return the original evidence set'; END IF;

  -- Record all but the final required scenario and prove premature submission fails.
  FOREACH scenario_code IN ARRAY scenarios[1:8] LOOP
    scenario_number:=scenario_number+1;
    PERFORM record_savings_provider_certification_scenario(
      org_id,maker_id,sandbox_cert,scenario_code,1,'passed',0,
      'evidence/scenario/'||scenario_code,evidence_hash,
      now_at-INTERVAL '10 minutes',now_at-INTERVAL '5 minutes',
      'sav06-sandbox-scenario-'||lpad(scenario_number::TEXT,3,'0'),now_at);
  END LOOP;
  failed:=FALSE;
  BEGIN
    PERFORM submit_savings_provider_certification(
      org_id,maker_id,sandbox_cert,'Submit incomplete evidence set',
      'sav06-submit-incomplete-001',now_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%checklist is incomplete%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV06: incomplete scenario evidence was submitted'; END IF;

  scenario_number:=9;
  PERFORM record_savings_provider_certification_scenario(
    org_id,maker_id,sandbox_cert,'servicing_after_disable',1,'passed',0,
    'evidence/scenario/servicing-after-disable',evidence_hash,
    now_at-INTERVAL '10 minutes',now_at-INTERVAL '5 minutes',
    'sav06-sandbox-scenario-009',now_at);
  PERFORM submit_savings_provider_certification(
    org_id,maker_id,sandbox_cert,'Complete sandbox evidence submitted for independent review',
    'sav06-submit-sandbox-001',now_at);
  failed:=FALSE;
  BEGIN
    PERFORM decide_savings_provider_certification(
      org_id,maker_id,sandbox_cert,TRUE,'Maker self approval must fail',
      'sav06-self-decide-001',now_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Maker cannot certify%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV06: maker certified their own evidence'; END IF;
  PERFORM decide_savings_provider_certification(
    org_id,checker_id,sandbox_cert,TRUE,'Independent checker verified all sandbox evidence',
    'sav06-certify-sandbox-001',now_at);

  result:=read_savings_provider_readiness(
    org_id,checker_id,'licensed.savings','sandbox','NG','NGN',fingerprint,now_at);
  IF NOT (result->>'ready')::BOOLEAN OR result->>'certificationId'<>sandbox_cert::TEXT
    OR jsonb_array_length(result->'missing')<>0
  THEN RAISE EXCEPTION 'SAV06: certified sandbox configuration was not ready: %',result; END IF;
  result:=read_savings_provider_readiness(
    org_id,checker_id,'licensed.savings','sandbox','NG','NGN',repeat('c',64),now_at);
  IF (result->>'ready')::BOOLEAN OR NOT(result->'missing' ? 'certified_provider_configuration')
  THEN RAISE EXCEPTION 'SAV06: uncertified configuration fingerprint became ready: %',result; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM read_savings_provider_readiness(
      org_id,outsider_id,'licensed.savings','sandbox','NG','NGN',fingerprint,now_at);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%permission%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV06: outsider read another tenant certification'; END IF;

  -- A live evidence set requires both independent certification and the
  -- separately approved financial live-activation record.
  result:=create_savings_provider_certification(
    org_id,maker_id,'licensed.savings','Licensed Savings Provider Limited','live','NG','NGN',1,
    fingerprint,'evidence/live-provider-contract','evidence/live-credential-validation','evidence/live-webhook-certification',
    'evidence/live-settlement-account','evidence/live-compliance-notes','evidence/live-threat-model','evidence/live-privacy-review',
    'evidence/live-support-runbook','evidence/live-reconciliation-signoff','evidence/live-limits-disclosures',maker_id,
    now_at+INTERVAL '1 year','sav06-create-live-001',now_at);
  live_cert:=(result->>'id')::UUID;
  scenario_number:=0;
  FOREACH scenario_code IN ARRAY scenarios LOOP
    scenario_number:=scenario_number+1;
    PERFORM record_savings_provider_certification_scenario(
      org_id,maker_id,live_cert,scenario_code,1,'passed',0,
      'evidence/live-scenario/'||scenario_code,evidence_hash,
      now_at-INTERVAL '10 minutes',now_at-INTERVAL '5 minutes',
      'sav06-live-scenario-'||lpad(scenario_number::TEXT,3,'0'),now_at);
  END LOOP;
  PERFORM submit_savings_provider_certification(
    org_id,maker_id,live_cert,'Complete controlled live evidence submitted for independent review',
    'sav06-submit-live-001',now_at);
  PERFORM decide_savings_provider_certification(
    org_id,checker_id,live_cert,TRUE,'Independent checker verified controlled live evidence',
    'sav06-certify-live-001',now_at);
  result:=read_savings_provider_readiness(
    org_id,checker_id,'licensed.savings','live','NG','NGN',fingerprint,now_at);
  IF (result->>'ready')::BOOLEAN OR NOT(result->'missing' ? 'live_activation')
  THEN RAISE EXCEPTION 'SAV06: live provider became ready without live activation: %',result; END IF;

  activation_id:=request_financial_live_activation(
    org_id,maker_id,'savings','NG','Licensed Savings Provider Limited',maker_id,
    'evidence/live-activation-approval','evidence/kyc-rules','evidence/regulatory-source',
    DATE '2026-01-01',now_at-INTERVAL '1 minute');
  PERFORM decide_financial_live_activation(
    activation_id,checker_id,TRUE,'Independent financial live activation approval');
  result:=read_savings_provider_readiness(
    org_id,checker_id,'licensed.savings','live','NG','NGN',fingerprint,now_at);
  IF NOT (result->>'ready')::BOOLEAN OR result->>'liveActivationId'<>activation_id::TEXT
  THEN RAISE EXCEPTION 'SAV06: independently activated live configuration was not ready: %',result; END IF;

  failed:=FALSE;
  BEGIN
    UPDATE savings_provider_certification_scenarios SET evidence_reference='tampered/evidence'
      WHERE id=(SELECT id FROM savings_provider_certification_scenarios
        WHERE certification_id=sandbox_cert ORDER BY created_at,id LIMIT 1);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%append-only%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV06: scenario evidence was mutable'; END IF;
END $$;
