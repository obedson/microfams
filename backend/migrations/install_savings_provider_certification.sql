-- SAV-06: tenant-scoped savings provider certification evidence and fail-closed
-- acquisition readiness. Evidence references and configuration fingerprints are
-- stored; credentials and raw provider secrets are never persisted here.

SET search_path=public,extensions;

CREATE TABLE savings_provider_certifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  provider_code TEXT NOT NULL CHECK (provider_code ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  provider_legal_name TEXT NOT NULL CHECK (length(btrim(provider_legal_name)) BETWEEN 2 AND 160),
  environment TEXT NOT NULL CHECK (environment IN ('sandbox','live')),
  jurisdiction CHAR(2) NOT NULL CHECK (jurisdiction=upper(jurisdiction)),
  currency CHAR(3) NOT NULL CHECK (currency=upper(currency)),
  version INTEGER NOT NULL CHECK (version>0),
  configuration_fingerprint CHAR(64) NOT NULL CHECK (configuration_fingerprint ~ '^[a-f0-9]{64}$'),
  provider_contract_reference TEXT NOT NULL CHECK (length(btrim(provider_contract_reference)) BETWEEN 8 AND 500),
  credentials_validation_reference TEXT NOT NULL CHECK (length(btrim(credentials_validation_reference)) BETWEEN 8 AND 500),
  webhook_certification_reference TEXT NOT NULL CHECK (length(btrim(webhook_certification_reference)) BETWEEN 8 AND 500),
  settlement_account_reference TEXT NOT NULL CHECK (length(btrim(settlement_account_reference)) BETWEEN 8 AND 500),
  compliance_notes_reference TEXT NOT NULL CHECK (length(btrim(compliance_notes_reference)) BETWEEN 8 AND 500),
  threat_model_reference TEXT NOT NULL CHECK (length(btrim(threat_model_reference)) BETWEEN 8 AND 500),
  data_protection_review_reference TEXT NOT NULL CHECK (length(btrim(data_protection_review_reference)) BETWEEN 8 AND 500),
  support_runbook_reference TEXT NOT NULL CHECK (length(btrim(support_runbook_reference)) BETWEEN 8 AND 500),
  reconciliation_signoff_reference TEXT NOT NULL CHECK (length(btrim(reconciliation_signoff_reference)) BETWEEN 8 AND 500),
  limits_disclosures_reference TEXT NOT NULL CHECK (length(btrim(limits_disclosures_reference)) BETWEEN 8 AND 500),
  operational_owner_id UUID NOT NULL REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','pending_approval','certified','rejected','suspended','retired')),
  created_by UUID NOT NULL REFERENCES users(id),
  submitted_at TIMESTAMPTZ,
  certified_by UUID REFERENCES users(id),
  certified_at TIMESTAMPTZ,
  valid_until TIMESTAMPTZ NOT NULL,
  creation_idempotency_key TEXT NOT NULL CHECK (length(creation_idempotency_key) BETWEEN 8 AND 160),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK (valid_until>created_at),
  CHECK (certified_by IS NULL OR certified_by<>created_by),
  CHECK ((status='certified')=(certified_at IS NOT NULL AND certified_by IS NOT NULL)),
  UNIQUE(organization_id,provider_code,environment,jurisdiction,currency,version),
  UNIQUE(organization_id,creation_idempotency_key)
);

CREATE INDEX idx_savings_provider_certification_lookup
  ON savings_provider_certifications(
    organization_id,provider_code,environment,jurisdiction,currency,status,valid_until DESC);

CREATE TABLE savings_provider_certification_scenarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  certification_id UUID NOT NULL REFERENCES savings_provider_certifications(id) ON DELETE CASCADE,
  scenario_code TEXT NOT NULL CHECK (scenario_code IN (
    'contribution_success','contribution_duplicate','contribution_failure',
    'standing_order_retry','withdrawal_success','withdrawal_failure',
    'provider_callback_replay','reconciliation_zero_variance','servicing_after_disable'
  )),
  attempt_number INTEGER NOT NULL CHECK (attempt_number>0),
  result TEXT NOT NULL CHECK (result IN ('passed','failed')),
  unexplained_variance_minor BIGINT NOT NULL DEFAULT 0 CHECK (unexplained_variance_minor>=0),
  evidence_reference TEXT NOT NULL CHECK (length(btrim(evidence_reference)) BETWEEN 8 AND 500),
  evidence_sha256 CHAR(64) NOT NULL CHECK (evidence_sha256 ~ '^[a-f0-9]{64}$'),
  started_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ NOT NULL,
  recorded_by UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK (completed_at>=started_at),
  CHECK (scenario_code='reconciliation_zero_variance' OR unexplained_variance_minor=0),
  UNIQUE(certification_id,scenario_code,attempt_number),
  UNIQUE(organization_id,idempotency_key)
);

CREATE INDEX idx_savings_provider_scenario_latest
  ON savings_provider_certification_scenarios(certification_id,scenario_code,attempt_number DESC);

CREATE TABLE savings_provider_certification_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  certification_id UUID NOT NULL REFERENCES savings_provider_certifications(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'created','scenario_recorded','submitted','certified','rejected','suspended','retired'
  )),
  actor_id UUID NOT NULL REFERENCES users(id),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 8 AND 1000),
  details JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(details)='object'),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(organization_id,idempotency_key)
);

CREATE INDEX idx_savings_provider_certification_events
  ON savings_provider_certification_events(certification_id,created_at,id);

CREATE OR REPLACE FUNCTION protect_savings_provider_certification_evidence()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  RAISE EXCEPTION 'Savings provider certification evidence is append-only';
END $$;

CREATE TRIGGER protect_savings_provider_scenario_mutation
  BEFORE UPDATE OR DELETE ON savings_provider_certification_scenarios
  FOR EACH ROW EXECUTE FUNCTION protect_savings_provider_certification_evidence();
CREATE TRIGGER protect_savings_provider_event_mutation
  BEFORE UPDATE OR DELETE ON savings_provider_certification_events
  FOR EACH ROW EXECUTE FUNCTION protect_savings_provider_certification_evidence();

CREATE OR REPLACE FUNCTION assert_savings_certification_actor(
  p_organization UUID,p_actor UUID
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.activation.manage') THEN
    RAISE EXCEPTION 'Missing financial.activation.manage permission';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION savings_provider_certification_checklist(p_certification UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications; v_missing TEXT[]:='{}'; v_latest RECORD;
DECLARE v_required TEXT[]:=ARRAY[
  'contribution_success','contribution_duplicate','contribution_failure',
  'standing_order_retry','withdrawal_success','withdrawal_failure',
  'provider_callback_replay','reconciliation_zero_variance','servicing_after_disable'];
DECLARE v_code TEXT;
BEGIN
  SELECT * INTO v_cert FROM savings_provider_certifications WHERE id=p_certification;
  IF v_cert.id IS NULL THEN RAISE EXCEPTION 'Savings provider certification not found'; END IF;
  FOREACH v_code IN ARRAY v_required LOOP
    SELECT scenario.result,scenario.unexplained_variance_minor INTO v_latest
    FROM savings_provider_certification_scenarios scenario
    WHERE scenario.certification_id=v_cert.id AND scenario.scenario_code=v_code
    ORDER BY scenario.attempt_number DESC LIMIT 1;
    IF v_latest.result IS NULL THEN
      v_missing:=array_append(v_missing,'scenario:'||v_code);
    ELSIF v_latest.result<>'passed' THEN
      v_missing:=array_append(v_missing,'scenario_failed:'||v_code);
    ELSIF v_code='reconciliation_zero_variance' AND v_latest.unexplained_variance_minor<>0 THEN
      v_missing:=array_append(v_missing,'reconciliation_variance');
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'complete',cardinality(v_missing)=0,
    'missing',to_jsonb(v_missing),
    'requiredScenarioCount',cardinality(v_required),
    'configurationFingerprint',v_cert.configuration_fingerprint,
    'validUntil',v_cert.valid_until);
END $$;

CREATE OR REPLACE FUNCTION create_savings_provider_certification(
  p_organization UUID,p_actor UUID,p_provider_code TEXT,p_provider_legal_name TEXT,
  p_environment TEXT,p_jurisdiction TEXT,p_currency TEXT,p_version INTEGER,
  p_configuration_fingerprint TEXT,p_provider_contract_reference TEXT,
  p_credentials_validation_reference TEXT,p_webhook_certification_reference TEXT,
  p_settlement_account_reference TEXT,p_compliance_notes_reference TEXT,
  p_threat_model_reference TEXT,p_data_protection_review_reference TEXT,
  p_support_runbook_reference TEXT,p_reconciliation_signoff_reference TEXT,
  p_limits_disclosures_reference TEXT,p_operational_owner UUID,p_valid_until TIMESTAMPTZ,
  p_idempotency_key TEXT,p_now TIMESTAMPTZ DEFAULT clock_timestamp()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications;
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  IF p_environment NOT IN ('sandbox','live') OR p_valid_until<=p_now THEN
    RAISE EXCEPTION 'Savings provider certification configuration is invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM organization_memberships
      WHERE organization_id=p_organization AND user_id=p_operational_owner AND status='active') THEN
    RAISE EXCEPTION 'Savings provider operational owner must be an active organization member';
  END IF;
  SELECT * INTO v_cert FROM savings_provider_certifications
    WHERE organization_id=p_organization AND creation_idempotency_key=p_idempotency_key;
  IF v_cert.id IS NOT NULL THEN
    IF v_cert.provider_code<>lower(p_provider_code) OR v_cert.environment<>p_environment
      OR v_cert.configuration_fingerprint<>lower(p_configuration_fingerprint)
    THEN RAISE EXCEPTION 'Savings provider certification idempotency conflict'; END IF;
    RETURN to_jsonb(v_cert);
  END IF;
  INSERT INTO savings_provider_certifications(
    organization_id,provider_code,provider_legal_name,environment,jurisdiction,currency,version,
    configuration_fingerprint,provider_contract_reference,credentials_validation_reference,
    webhook_certification_reference,settlement_account_reference,compliance_notes_reference,
    threat_model_reference,data_protection_review_reference,support_runbook_reference,
    reconciliation_signoff_reference,limits_disclosures_reference,operational_owner_id,
    created_by,valid_until,creation_idempotency_key,created_at
  ) VALUES (
    p_organization,lower(p_provider_code),btrim(p_provider_legal_name),p_environment,
    upper(p_jurisdiction),upper(p_currency),p_version,lower(p_configuration_fingerprint),
    btrim(p_provider_contract_reference),btrim(p_credentials_validation_reference),
    btrim(p_webhook_certification_reference),btrim(p_settlement_account_reference),
    btrim(p_compliance_notes_reference),btrim(p_threat_model_reference),
    btrim(p_data_protection_review_reference),btrim(p_support_runbook_reference),
    btrim(p_reconciliation_signoff_reference),btrim(p_limits_disclosures_reference),
    p_operational_owner,p_actor,p_valid_until,p_idempotency_key,p_now
  ) RETURNING * INTO v_cert;
  INSERT INTO savings_provider_certification_events(
    organization_id,certification_id,event_type,actor_id,reason,details,idempotency_key,created_at
  ) VALUES (p_organization,v_cert.id,'created',p_actor,'Certification evidence set created',
    jsonb_build_object('environment',p_environment,'providerCode',lower(p_provider_code)),
    left(p_idempotency_key,154)||':event',p_now);
  RETURN to_jsonb(v_cert);
END $$;

CREATE OR REPLACE FUNCTION record_savings_provider_certification_scenario(
  p_organization UUID,p_actor UUID,p_certification UUID,p_scenario_code TEXT,
  p_attempt_number INTEGER,p_result TEXT,p_unexplained_variance_minor BIGINT,
  p_evidence_reference TEXT,p_evidence_sha256 TEXT,
  p_started_at TIMESTAMPTZ,p_completed_at TIMESTAMPTZ,p_idempotency_key TEXT,
  p_now TIMESTAMPTZ DEFAULT clock_timestamp()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications; v_scenario savings_provider_certification_scenarios;
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  SELECT * INTO v_cert FROM savings_provider_certifications
    WHERE id=p_certification AND organization_id=p_organization FOR UPDATE;
  IF v_cert.id IS NULL OR v_cert.status<>'draft' THEN
    RAISE EXCEPTION 'Draft savings provider certification not found';
  END IF;
  SELECT * INTO v_scenario FROM savings_provider_certification_scenarios
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_scenario.id IS NOT NULL THEN
    IF v_scenario.certification_id<>p_certification OR v_scenario.scenario_code<>p_scenario_code
      OR v_scenario.attempt_number<>p_attempt_number OR v_scenario.result<>p_result
    THEN RAISE EXCEPTION 'Savings provider scenario idempotency conflict'; END IF;
    RETURN to_jsonb(v_scenario);
  END IF;
  INSERT INTO savings_provider_certification_scenarios(
    organization_id,certification_id,scenario_code,attempt_number,result,
    unexplained_variance_minor,evidence_reference,evidence_sha256,
    started_at,completed_at,recorded_by,idempotency_key,created_at
  ) VALUES (
    p_organization,p_certification,p_scenario_code,p_attempt_number,p_result,
    p_unexplained_variance_minor,btrim(p_evidence_reference),lower(p_evidence_sha256),
    p_started_at,p_completed_at,p_actor,p_idempotency_key,p_now
  ) RETURNING * INTO v_scenario;
  INSERT INTO savings_provider_certification_events(
    organization_id,certification_id,event_type,actor_id,reason,details,idempotency_key,created_at
  ) VALUES (p_organization,p_certification,'scenario_recorded',p_actor,
    'Certification scenario evidence recorded',jsonb_build_object(
      'scenarioCode',p_scenario_code,'attemptNumber',p_attempt_number,'result',p_result),
    left(p_idempotency_key,154)||':event',p_now);
  RETURN to_jsonb(v_scenario);
END $$;

CREATE OR REPLACE FUNCTION submit_savings_provider_certification(
  p_organization UUID,p_actor UUID,p_certification UUID,p_reason TEXT,
  p_idempotency_key TEXT,p_now TIMESTAMPTZ DEFAULT clock_timestamp()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications; v_check JSONB; v_event savings_provider_certification_events;
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  SELECT * INTO v_event FROM savings_provider_certification_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.certification_id<>p_certification OR v_event.event_type<>'submitted'
    THEN RAISE EXCEPTION 'Savings provider certification idempotency conflict'; END IF;
    SELECT * INTO v_cert FROM savings_provider_certifications WHERE id=p_certification;
    RETURN to_jsonb(v_cert);
  END IF;
  SELECT * INTO v_cert FROM savings_provider_certifications
    WHERE id=p_certification AND organization_id=p_organization FOR UPDATE;
  IF v_cert.id IS NULL OR v_cert.status<>'draft' THEN
    RAISE EXCEPTION 'Draft savings provider certification not found';
  END IF;
  v_check:=savings_provider_certification_checklist(v_cert.id);
  IF NOT (v_check->>'complete')::BOOLEAN THEN
    RAISE EXCEPTION 'Savings provider certification checklist is incomplete';
  END IF;
  UPDATE savings_provider_certifications SET status='pending_approval',submitted_at=p_now
    WHERE id=v_cert.id RETURNING * INTO v_cert;
  INSERT INTO savings_provider_certification_events(
    organization_id,certification_id,event_type,actor_id,reason,details,idempotency_key,created_at
  ) VALUES (p_organization,p_certification,'submitted',p_actor,btrim(p_reason),v_check,p_idempotency_key,p_now);
  RETURN to_jsonb(v_cert);
END $$;

CREATE OR REPLACE FUNCTION decide_savings_provider_certification(
  p_organization UUID,p_actor UUID,p_certification UUID,p_approve BOOLEAN,p_reason TEXT,
  p_idempotency_key TEXT,p_now TIMESTAMPTZ DEFAULT clock_timestamp()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications; v_check JSONB; v_event savings_provider_certification_events;
DECLARE v_event_type TEXT:=CASE WHEN p_approve THEN 'certified' ELSE 'rejected' END;
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  SELECT * INTO v_event FROM savings_provider_certification_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.certification_id<>p_certification OR v_event.event_type<>v_event_type
    THEN RAISE EXCEPTION 'Savings provider certification idempotency conflict'; END IF;
    SELECT * INTO v_cert FROM savings_provider_certifications WHERE id=p_certification;
    RETURN to_jsonb(v_cert);
  END IF;
  SELECT * INTO v_cert FROM savings_provider_certifications
    WHERE id=p_certification AND organization_id=p_organization FOR UPDATE;
  IF v_cert.id IS NULL OR v_cert.status<>'pending_approval' THEN
    RAISE EXCEPTION 'Pending savings provider certification not found';
  END IF;
  IF v_cert.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot certify their own evidence'; END IF;
  IF p_approve THEN
    v_check:=savings_provider_certification_checklist(v_cert.id);
    IF NOT (v_check->>'complete')::BOOLEAN OR v_cert.valid_until<=p_now THEN
      RAISE EXCEPTION 'Savings provider certification is not approval-ready';
    END IF;
  ELSE v_check:='{}'::JSONB; END IF;
  UPDATE savings_provider_certifications SET
    status=CASE WHEN p_approve THEN 'certified' ELSE 'rejected' END,
    certified_by=CASE WHEN p_approve THEN p_actor ELSE NULL END,
    certified_at=CASE WHEN p_approve THEN p_now ELSE NULL END
  WHERE id=v_cert.id RETURNING * INTO v_cert;
  INSERT INTO savings_provider_certification_events(
    organization_id,certification_id,event_type,actor_id,reason,details,idempotency_key,created_at
  ) VALUES (p_organization,p_certification,v_event_type,p_actor,btrim(p_reason),v_check,p_idempotency_key,p_now);
  RETURN to_jsonb(v_cert);
END $$;

CREATE OR REPLACE FUNCTION read_savings_provider_readiness(
  p_organization UUID,p_actor UUID,p_provider_code TEXT,p_environment TEXT,
  p_jurisdiction TEXT,p_currency TEXT,p_configuration_fingerprint TEXT,
  p_now TIMESTAMPTZ DEFAULT clock_timestamp()
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cert savings_provider_certifications; v_activation financial_live_activations;
DECLARE v_missing TEXT[]:='{}'; v_check JSONB;
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  SELECT * INTO v_cert FROM savings_provider_certifications
  WHERE organization_id=p_organization AND provider_code=lower(p_provider_code)
    AND environment=p_environment AND jurisdiction=upper(p_jurisdiction)
    AND currency=upper(p_currency) AND configuration_fingerprint=lower(p_configuration_fingerprint)
    AND status='certified' AND certified_at<=p_now AND valid_until>p_now
  ORDER BY version DESC LIMIT 1;
  IF v_cert.id IS NULL THEN
    v_missing:=array_append(v_missing,'certified_provider_configuration');
  ELSE
    v_check:=savings_provider_certification_checklist(v_cert.id);
    IF NOT (v_check->>'complete')::BOOLEAN THEN
      v_missing:=array_append(v_missing,'certification_checklist');
    END IF;
  END IF;
  IF p_environment='live' THEN
    SELECT * INTO v_activation FROM financial_live_activations activation
    WHERE activation.organization_id=p_organization AND activation.product='savings'
      AND activation.jurisdiction=upper(p_jurisdiction) AND activation.status='active'
      AND activation.effective_from<=p_now
      AND (activation.effective_until IS NULL OR activation.effective_until>p_now)
      AND v_cert.id IS NOT NULL
      AND lower(activation.licensed_provider)=lower(v_cert.provider_legal_name)
    ORDER BY activation.effective_from DESC LIMIT 1;
    IF v_activation.id IS NULL THEN v_missing:=array_append(v_missing,'live_activation'); END IF;
  END IF;
  RETURN jsonb_build_object(
    'ready',cardinality(v_missing)=0,'organizationId',p_organization,
    'providerCode',lower(p_provider_code),'environment',p_environment,
    'jurisdiction',upper(p_jurisdiction),'currency',upper(p_currency),
    'certificationId',v_cert.id,'certificationVersion',v_cert.version,
    'validUntil',v_cert.valid_until,'liveActivationId',v_activation.id,
    'missing',to_jsonb(v_missing));
END $$;

CREATE OR REPLACE FUNCTION list_savings_provider_certifications(
  p_organization UUID,p_actor UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
  PERFORM assert_savings_certification_actor(p_organization,p_actor);
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',cert.id,'providerCode',cert.provider_code,'providerLegalName',cert.provider_legal_name,
    'environment',cert.environment,'jurisdiction',cert.jurisdiction,'currency',cert.currency,
    'version',cert.version,'configurationFingerprint',cert.configuration_fingerprint,
    'providerContractReference',cert.provider_contract_reference,
    'credentialsValidationReference',cert.credentials_validation_reference,
    'webhookCertificationReference',cert.webhook_certification_reference,
    'settlementAccountReference',cert.settlement_account_reference,
    'complianceNotesReference',cert.compliance_notes_reference,
    'threatModelReference',cert.threat_model_reference,
    'dataProtectionReviewReference',cert.data_protection_review_reference,
    'supportRunbookReference',cert.support_runbook_reference,
    'reconciliationSignoffReference',cert.reconciliation_signoff_reference,
    'limitsDisclosuresReference',cert.limits_disclosures_reference,
    'operationalOwnerId',cert.operational_owner_id,
    'status',cert.status,'createdBy',cert.created_by,'submittedAt',cert.submitted_at,
    'certifiedBy',cert.certified_by,'certifiedAt',cert.certified_at,
    'validUntil',cert.valid_until,'createdAt',cert.created_at,
    'checklist',savings_provider_certification_checklist(cert.id),
    'scenarios',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',scenario.id,'scenarioCode',scenario.scenario_code,
      'attemptNumber',scenario.attempt_number,'result',scenario.result,
      'unexplainedVarianceMinor',scenario.unexplained_variance_minor::TEXT,
      'evidenceReference',scenario.evidence_reference,'evidenceSha256',scenario.evidence_sha256,
      'startedAt',scenario.started_at,'completedAt',scenario.completed_at,
      'recordedBy',scenario.recorded_by,'createdAt',scenario.created_at
    ) ORDER BY scenario.scenario_code,scenario.attempt_number)
      FROM savings_provider_certification_scenarios scenario
      WHERE scenario.certification_id=cert.id),'[]'::JSONB),
    'events',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',event.id,'eventType',event.event_type,'actorId',event.actor_id,
      'reason',event.reason,'details',event.details,'createdAt',event.created_at
    ) ORDER BY event.created_at,event.id)
      FROM savings_provider_certification_events event
      WHERE event.certification_id=cert.id),'[]'::JSONB)
  ) ORDER BY cert.created_at DESC,cert.id DESC)
  FROM savings_provider_certifications cert WHERE cert.organization_id=p_organization),'[]'::JSONB);
END $$;

ALTER TABLE savings_provider_certifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_provider_certification_scenarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_provider_certification_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY savings_provider_certification_tenant_read ON savings_provider_certifications
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY savings_provider_certification_scenario_tenant_read ON savings_provider_certification_scenarios
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY savings_provider_certification_event_tenant_read ON savings_provider_certification_events
  FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON savings_provider_certifications,savings_provider_certification_scenarios,
  savings_provider_certification_events FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION
  assert_savings_certification_actor(UUID,UUID),
  savings_provider_certification_checklist(UUID),
  create_savings_provider_certification(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),
  record_savings_provider_certification_scenario(UUID,UUID,UUID,TEXT,INTEGER,TEXT,BIGINT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),
  submit_savings_provider_certification(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ),
  decide_savings_provider_certification(UUID,UUID,UUID,BOOLEAN,TEXT,TEXT,TIMESTAMPTZ),
  read_savings_provider_readiness(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ),
  list_savings_provider_certifications(UUID,UUID)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  create_savings_provider_certification(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),
  record_savings_provider_certification_scenario(UUID,UUID,UUID,TEXT,INTEGER,TEXT,BIGINT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),
  submit_savings_provider_certification(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ),
  decide_savings_provider_certification(UUID,UUID,UUID,BOOLEAN,TEXT,TEXT,TIMESTAMPTZ),
  read_savings_provider_readiness(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ),
  list_savings_provider_certifications(UUID,UUID)
  TO service_role;
