-- CRD-02: tenant-scoped loan applications, deterministic eligibility and
-- affordability screening, explainable adverse decisions, and human review.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION valid_loan_reference_array(p_references JSONB) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_typeof(p_references) = 'array'
    AND jsonb_array_length(p_references) <= 20
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(p_references) reference
      WHERE reference !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$'
    );
$$;

CREATE TABLE loan_applications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  product_id UUID NOT NULL,
  product_version_id UUID NOT NULL,
  product_version INTEGER NOT NULL CHECK (product_version > 0),
  applicant_user_id UUID NOT NULL REFERENCES users(id),
  borrower_type TEXT NOT NULL CHECK (borrower_type IN ('individual','group','organization')),
  borrower_user_id UUID REFERENCES users(id),
  borrower_group_id UUID REFERENCES groups(id),
  borrower_organization_id UUID REFERENCES organizations(id),
  purpose TEXT NOT NULL CHECK (purpose ~ '^[a-z][a-z0-9_]{1,39}$'),
  requested_principal_minor BIGINT NOT NULL CHECK (requested_principal_minor > 0),
  requested_tenor_days INTEGER NOT NULL CHECK (requested_tenor_days > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  monthly_net_income_minor BIGINT NOT NULL CHECK (monthly_net_income_minor > 0),
  monthly_existing_debt_minor BIGINT NOT NULL CHECK (monthly_existing_debt_minor >= 0),
  verified_income_months INTEGER NOT NULL CHECK (verified_income_months >= 0),
  income_evidence_references JSONB NOT NULL DEFAULT '[]'::JSONB
    CHECK (valid_loan_reference_array(income_evidence_references)),
  identity_evidence_id UUID REFERENCES verified_identities(id),
  disclosure_version TEXT NOT NULL CHECK (length(btrim(disclosure_version)) BETWEEN 1 AND 80),
  disclosure_content_hash VARCHAR(64) NOT NULL CHECK (disclosure_content_hash ~ '^[a-f0-9]{64}$'),
  declaration_version TEXT NOT NULL CHECK (length(btrim(declaration_version)) BETWEEN 1 AND 80),
  declaration_content_hash VARCHAR(64) NOT NULL CHECK (declaration_content_hash ~ '^[a-f0-9]{64}$'),
  declaration_accepted_at TIMESTAMPTZ NOT NULL,
  product_rule_snapshot JSONB NOT NULL CHECK (jsonb_typeof(product_rule_snapshot) = 'object'),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN (
    'draft','submitted','identity_review','affordability_review','credit_review',
    'declined','withdrawn','cancelled'
  )),
  creation_key TEXT NOT NULL CHECK (length(creation_key) BETWEEN 8 AND 160),
  creation_hash VARCHAR(64) NOT NULL CHECK (creation_hash ~ '^[a-f0-9]{64}$'),
  submitted_at TIMESTAMPTZ,
  decided_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (product_id, organization_id) REFERENCES loan_products(id, organization_id),
  FOREIGN KEY (product_version_id, organization_id) REFERENCES loan_product_versions(id, organization_id),
  UNIQUE (organization_id, creation_key),
  UNIQUE (id, organization_id),
  CHECK (num_nonnulls(borrower_user_id, borrower_group_id, borrower_organization_id) = 1),
  CHECK (
    (borrower_type = 'individual' AND borrower_user_id IS NOT NULL)
    OR (borrower_type = 'group' AND borrower_group_id IS NOT NULL)
    OR (borrower_type = 'organization' AND borrower_organization_id IS NOT NULL)
  )
);
CREATE INDEX idx_loan_applications_subject
  ON loan_applications(organization_id, applicant_user_id, created_at DESC);
CREATE INDEX idx_loan_applications_review_queue
  ON loan_applications(organization_id, state, updated_at)
  WHERE state IN ('credit_review','declined');

CREATE TABLE loan_application_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  stage TEXT NOT NULL CHECK (stage IN ('eligibility','identity','affordability','human_adverse_review')),
  model_code TEXT NOT NULL CHECK (length(btrim(model_code)) BETWEEN 2 AND 80),
  model_version TEXT NOT NULL CHECK (length(btrim(model_version)) BETWEEN 1 AND 80),
  result TEXT NOT NULL CHECK (result IN ('pass','fail','manual_review','overridden')),
  reason_codes TEXT[] NOT NULL CHECK (cardinality(reason_codes) > 0),
  input_facts JSONB NOT NULL CHECK (jsonb_typeof(input_facts) = 'object'),
  rules_snapshot JSONB NOT NULL CHECK (jsonb_typeof(rules_snapshot) = 'object'),
  automated BOOLEAN NOT NULL,
  reviewer_id UUID REFERENCES users(id),
  override_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (application_id, organization_id) REFERENCES loan_applications(id, organization_id),
  UNIQUE (organization_id, application_id, sequence),
  UNIQUE (id, organization_id),
  CHECK ((automated AND reviewer_id IS NULL AND override_reason IS NULL)
    OR (NOT automated AND reviewer_id IS NOT NULL)),
  CHECK (result <> 'overridden' OR length(btrim(override_reason)) BETWEEN 12 AND 1000)
);

CREATE TABLE loan_adverse_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  adverse_decision_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'eligible' CHECK (state IN (
    'eligible','requested','under_review','upheld','reopened','withdrawn'
  )),
  reason_codes TEXT[] NOT NULL CHECK (cardinality(reason_codes) > 0),
  notice_version TEXT NOT NULL,
  notice_content_hash VARCHAR(64) NOT NULL CHECK (notice_content_hash ~ '^[a-f0-9]{64}$'),
  issued_at TIMESTAMPTZ NOT NULL,
  requested_by UUID REFERENCES users(id),
  request_reason TEXT,
  evidence_references JSONB NOT NULL DEFAULT '[]'::JSONB
    CHECK (valid_loan_reference_array(evidence_references)),
  requested_at TIMESTAMPTZ,
  decided_by UUID REFERENCES users(id),
  decision_reason TEXT,
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (application_id, organization_id) REFERENCES loan_applications(id, organization_id),
  FOREIGN KEY (adverse_decision_id, organization_id) REFERENCES loan_application_decisions(id, organization_id),
  UNIQUE (organization_id, application_id),
  UNIQUE (id, organization_id),
  CHECK ((state = 'eligible' AND requested_by IS NULL AND requested_at IS NULL)
    OR state <> 'eligible'),
  CHECK ((state IN ('upheld','reopened') AND decided_by IS NOT NULL AND decided_at IS NOT NULL
    AND length(btrim(decision_reason)) BETWEEN 12 AND 1000) OR state NOT IN ('upheld','reopened'))
);

CREATE TABLE loan_application_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN (
    'application_created','application_submitted','adverse_review_requested',
    'adverse_review_upheld','adverse_review_reopened','application_withdrawn'
  )),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (application_id, organization_id) REFERENCES loan_applications(id, organization_id),
  UNIQUE (organization_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION require_loan_application_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_application_engine', TRUE) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'LOAN_APPLICATION_ENGINE_REQUIRED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER loan_applications_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_applications
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_application_decisions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_application_decisions
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_adverse_reviews_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_adverse_reviews
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_application_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_application_events
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();

CREATE OR REPLACE FUNCTION append_loan_application_decision(
  p_application loan_applications,p_stage TEXT,p_result TEXT,p_reasons TEXT[],
  p_input JSONB,p_rules JSONB,p_automated BOOLEAN,p_reviewer UUID,p_override_reason TEXT,p_at TIMESTAMPTZ
) RETURNS loan_application_decisions LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_decision loan_application_decisions; v_sequence INTEGER;
BEGIN
  SELECT COALESCE(MAX(sequence),0)+1 INTO v_sequence FROM loan_application_decisions
    WHERE organization_id=p_application.organization_id AND application_id=p_application.id;
  INSERT INTO loan_application_decisions(organization_id,application_id,sequence,stage,model_code,model_version,
    result,reason_codes,input_facts,rules_snapshot,automated,reviewer_id,override_reason,created_at)
  VALUES(p_application.organization_id,p_application.id,v_sequence,p_stage,
    CASE WHEN p_automated THEN 'microfams_credit_rules' ELSE 'human_adverse_review' END,
    CASE WHEN p_automated THEN 'CRD-02.1' ELSE 'CRD-02.HUMAN.1' END,
    p_result,p_reasons,p_input,p_rules,p_automated,p_reviewer,p_override_reason,p_at)
  RETURNING * INTO v_decision;
  RETURN v_decision;
END $$;

CREATE OR REPLACE FUNCTION create_loan_adverse_review(
  p_application loan_applications,p_decision loan_application_decisions,p_at TIMESTAMPTZ
) RETURNS loan_adverse_reviews LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_review loan_adverse_reviews;
BEGIN
  INSERT INTO loan_adverse_reviews(organization_id,application_id,adverse_decision_id,reason_codes,
    notice_version,notice_content_hash,issued_at,created_at,updated_at)
  VALUES(p_application.organization_id,p_application.id,p_decision.id,p_decision.reason_codes,
    'CRD-02.ADVERSE.1','090c52c3fe0939973ba615d1f62259a626cca772c8d26884805e0ba294f25850',p_at,p_at,p_at)
  RETURNING * INTO v_review;
  RETURN v_review;
END $$;

CREATE OR REPLACE FUNCTION create_loan_application_draft(
  p_organization UUID,p_actor UUID,p_product UUID,p_borrower_type TEXT,p_borrower UUID,
  p_purpose TEXT,p_principal_minor BIGINT,p_tenor_days INTEGER,p_monthly_income_minor BIGINT,
  p_monthly_debt_minor BIGINT,p_verified_income_months INTEGER,p_income_evidence JSONB,
  p_identity_evidence UUID,p_disclosure_version TEXT,p_disclosure_hash TEXT,
  p_declaration_version TEXT,p_declaration_hash TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product loan_products; v_version loan_product_versions; v_application loan_applications;
  v_event loan_application_events; v_hash TEXT; v_borrower_user UUID; v_borrower_group UUID; v_borrower_org UUID;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active')
  THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  IF p_borrower_type NOT IN ('individual','group','organization') THEN RAISE EXCEPTION 'Borrower type is invalid'; END IF;
  IF p_purpose IS NULL OR p_purpose !~ '^[a-z][a-z0-9_]{1,39}$' OR p_principal_minor<=0 OR p_tenor_days<=0
    OR p_monthly_income_minor<=0 OR p_monthly_debt_minor<0 OR p_verified_income_months<0
    OR NOT valid_loan_reference_array(p_income_evidence)
  THEN RAISE EXCEPTION 'Loan application facts are invalid'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR COALESCE(p_disclosure_hash,'') !~ '^[a-f0-9]{64}$' OR COALESCE(p_declaration_hash,'') !~ '^[a-f0-9]{64}$'
    OR length(btrim(COALESCE(p_declaration_version,''))) NOT BETWEEN 1 AND 80
  THEN RAISE EXCEPTION 'Loan application evidence is invalid'; END IF;

  SELECT * INTO v_product FROM loan_products WHERE id=p_product AND organization_id=p_organization AND state='active';
  IF v_product.id IS NULL THEN RAISE EXCEPTION 'Active loan product was not found'; END IF;
  SELECT * INTO v_version FROM loan_product_versions
    WHERE product_id=v_product.id AND organization_id=p_organization AND version=v_product.current_version AND state='active';
  IF v_version.id IS NULL OR btrim(p_disclosure_version)<>v_version.disclosure_version
    OR p_disclosure_hash<>v_version.disclosure_content_hash
  THEN RAISE EXCEPTION 'Accepted disclosure does not match the active loan product'; END IF;

  IF p_borrower_type='individual' THEN
    IF p_borrower IS NOT NULL AND p_borrower<>p_actor THEN RAISE EXCEPTION 'Individuals may apply only for themselves'; END IF;
    v_borrower_user:=p_actor;
  ELSIF p_borrower_type='group' THEN
    IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.apply_on_behalf') THEN
      RAISE EXCEPTION 'Missing financial.loans.apply_on_behalf permission'; END IF;
    IF NOT EXISTS(SELECT 1 FROM groups WHERE id=p_borrower AND organization_id=p_organization AND lifecycle_state='active')
    THEN RAISE EXCEPTION 'Active borrower group was not found'; END IF;
    v_borrower_group:=p_borrower;
  ELSE
    IF p_borrower<>p_organization OR NOT has_financial_permission(p_organization,p_actor,'financial.loans.apply_on_behalf') THEN
      RAISE EXCEPTION 'Organization applications require delegated authority'; END IF;
    v_borrower_org:=p_organization;
  END IF;
  IF p_identity_evidence IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM verified_identities WHERE id=p_identity_evidence AND organization_id=p_organization
      AND user_id=p_actor AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'Identity evidence is unavailable for this applicant'; END IF;

  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_borrower_type,
    COALESCE(p_borrower::TEXT,''),p_purpose,p_principal_minor::TEXT,p_tenor_days::TEXT,p_monthly_income_minor::TEXT,
    p_monthly_debt_minor::TEXT,p_verified_income_months::TEXT,p_income_evidence::TEXT,COALESCE(p_identity_evidence::TEXT,''),
    p_disclosure_version,p_disclosure_hash,p_declaration_version,p_declaration_hash),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_idempotency_key,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different application facts'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application));
  END IF;

  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_applications(organization_id,product_id,product_version_id,product_version,applicant_user_id,
    borrower_type,borrower_user_id,borrower_group_id,borrower_organization_id,purpose,requested_principal_minor,
    requested_tenor_days,currency,monthly_net_income_minor,monthly_existing_debt_minor,verified_income_months,
    income_evidence_references,identity_evidence_id,disclosure_version,disclosure_content_hash,declaration_version,
    declaration_content_hash,declaration_accepted_at,product_rule_snapshot,creation_key,creation_hash,created_at,updated_at)
  VALUES(p_organization,v_product.id,v_version.id,v_version.version,p_actor,p_borrower_type,v_borrower_user,v_borrower_group,
    v_borrower_org,p_purpose,p_principal_minor,p_tenor_days,v_product.currency,p_monthly_income_minor,p_monthly_debt_minor,
    p_verified_income_months,p_income_evidence,p_identity_evidence,v_version.disclosure_version,v_version.disclosure_content_hash,
    btrim(p_declaration_version),p_declaration_hash,p_at,
    jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version)),p_idempotency_key,v_hash,p_at,p_at)
  RETURNING * INTO v_application;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,v_application.id,'application_created',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('product_version',v_version.version,'borrower_type',p_borrower_type,'disclosure_version',v_version.disclosure_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_APPLICATION_DRAFTED','loan_application',v_application.id::TEXT,
    jsonb_build_object('product_id',v_product.id,'product_version',v_version.version,'borrower_type',p_borrower_type),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application));
END $$;

CREATE OR REPLACE FUNCTION submit_loan_application(
  p_organization UUID,p_actor UUID,p_application UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_version loan_product_versions; v_event loan_application_events;
  v_decision loan_application_decisions; v_adverse loan_adverse_reviews; v_hash TEXT; v_reasons TEXT[];
  v_required_identity TEXT; v_min_income_months INTEGER; v_max_dsr INTEGER;
  v_total_cost BIGINT; v_estimated_monthly BIGINT; v_dsr BIGINT; v_affordability_result TEXT;
BEGIN
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,'submit'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different application command'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',(
      SELECT to_jsonb(r) FROM loan_adverse_reviews r WHERE r.application_id=v_application.id));
  END IF;
  SELECT * INTO v_application FROM loan_applications WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id<>p_actor OR v_application.state<>'draft'
  THEN RAISE EXCEPTION 'Loan application is not an applicant-owned draft'; END IF;
  SELECT * INTO v_version FROM loan_product_versions WHERE id=v_application.product_version_id AND organization_id=p_organization;
  IF v_version.id IS NULL THEN RAISE EXCEPTION 'Pinned loan product version is unavailable'; END IF;

  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_applications SET state='submitted',submitted_at=p_at,updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;

  v_reasons:=ARRAY[]::TEXT[];
  IF NOT (v_application.borrower_type=ANY(v_version.eligible_borrower_types)) THEN v_reasons:=array_append(v_reasons,'BORROWER_TYPE_NOT_ELIGIBLE'); END IF;
  IF NOT (v_application.purpose=ANY(v_version.purposes)) THEN v_reasons:=array_append(v_reasons,'PURPOSE_NOT_ELIGIBLE'); END IF;
  IF v_application.requested_principal_minor NOT BETWEEN v_version.minimum_principal_minor AND v_version.maximum_principal_minor
  THEN v_reasons:=array_append(v_reasons,'PRINCIPAL_OUTSIDE_PRODUCT_LIMITS'); END IF;
  IF v_application.requested_tenor_days NOT BETWEEN v_version.minimum_tenor_days AND v_version.maximum_tenor_days
  THEN v_reasons:=array_append(v_reasons,'TENOR_OUTSIDE_PRODUCT_LIMITS'); END IF;
  v_decision:=append_loan_application_decision(v_application,'eligibility',CASE WHEN cardinality(v_reasons)=0 THEN 'pass' ELSE 'fail' END,
    CASE WHEN cardinality(v_reasons)=0 THEN ARRAY['PRODUCT_ELIGIBILITY_PASSED']::TEXT[] ELSE v_reasons END,
    jsonb_build_object('borrower_type',v_application.borrower_type,'purpose',v_application.purpose,
      'requested_principal_minor',v_application.requested_principal_minor,'requested_tenor_days',v_application.requested_tenor_days),
    jsonb_build_object('eligible_borrower_types',v_version.eligible_borrower_types,'purposes',v_version.purposes,
      'minimum_principal_minor',v_version.minimum_principal_minor,'maximum_principal_minor',v_version.maximum_principal_minor,
      'minimum_tenor_days',v_version.minimum_tenor_days,'maximum_tenor_days',v_version.maximum_tenor_days),TRUE,NULL,NULL,p_at);
  IF v_decision.result='fail' THEN
    UPDATE loan_applications SET state='declined',decided_at=p_at,updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
    v_adverse:=create_loan_adverse_review(v_application,v_decision,p_at);
  ELSE
    UPDATE loan_applications SET state='identity_review',updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
    v_required_identity:=COALESCE(NULLIF(v_version.affordability_rules->>'requiredIdentityTier',''),'nin_verified');
    v_reasons:=ARRAY[]::TEXT[];
    IF v_required_identity NOT IN ('none','nin_verified','bvn_verified') THEN
      v_reasons:=array_append(v_reasons,'IDENTITY_RULE_UNSUPPORTED');
    ELSIF v_required_identity<>'none' AND NOT EXISTS(
      SELECT 1 FROM verified_identities identity
      WHERE identity.id=v_application.identity_evidence_id AND identity.organization_id=p_organization
        AND identity.user_id=v_application.applicant_user_id AND identity.revoked_at IS NULL
        AND identity.evidence_type=CASE WHEN v_required_identity='nin_verified' THEN 'nin' ELSE 'bvn' END
    ) THEN v_reasons:=array_append(v_reasons,'VERIFIED_IDENTITY_REQUIRED'); END IF;
    v_decision:=append_loan_application_decision(v_application,'identity',CASE WHEN cardinality(v_reasons)=0 THEN 'pass' ELSE 'fail' END,
      CASE WHEN cardinality(v_reasons)=0 THEN ARRAY['IDENTITY_REQUIREMENT_PASSED']::TEXT[] ELSE v_reasons END,
      jsonb_build_object('identity_evidence_id',v_application.identity_evidence_id),
      jsonb_build_object('required_identity_tier',v_required_identity),TRUE,NULL,NULL,p_at);
    IF v_decision.result='fail' THEN
      UPDATE loan_applications SET state='declined',decided_at=p_at,updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
      v_adverse:=create_loan_adverse_review(v_application,v_decision,p_at);
    ELSE
      UPDATE loan_applications SET state='affordability_review',updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
      v_reasons:=ARRAY[]::TEXT[]; v_affordability_result:='pass';
      IF COALESCE(v_version.affordability_rules->>'minimumVerifiedIncomeMonths','') !~ '^[0-9]+$'
        OR COALESCE(v_version.affordability_rules->>'maximumDebtServiceRatioBasisPoints','') !~ '^[1-9][0-9]*$'
        OR (v_version.affordability_rules->>'maximumDebtServiceRatioBasisPoints')::BIGINT>10000 THEN
        v_affordability_result:='manual_review';
        v_reasons:=ARRAY['AFFORDABILITY_RULE_REQUIRES_MANUAL_REVIEW']::TEXT[];
        v_min_income_months:=NULL; v_max_dsr:=NULL;
      ELSE
        v_min_income_months:=(v_version.affordability_rules->>'minimumVerifiedIncomeMonths')::INTEGER;
        v_max_dsr:=(v_version.affordability_rules->>'maximumDebtServiceRatioBasisPoints')::INTEGER;
        v_total_cost:=v_application.requested_principal_minor + CEIL(
          v_application.requested_principal_minor::NUMERIC*v_version.effective_annual_cost_basis_points::NUMERIC
          *v_application.requested_tenor_days::NUMERIC/3650000::NUMERIC)::BIGINT;
        v_estimated_monthly:=CEIL(v_total_cost::NUMERIC/GREATEST(1,CEIL(v_application.requested_tenor_days::NUMERIC/30)))::BIGINT;
        v_dsr:=CEIL((v_application.monthly_existing_debt_minor+v_estimated_monthly)::NUMERIC*10000
          /v_application.monthly_net_income_minor)::BIGINT;
        IF v_application.verified_income_months<v_min_income_months THEN
          v_reasons:=array_append(v_reasons,'INSUFFICIENT_VERIFIED_INCOME_HISTORY'); END IF;
        IF v_dsr>v_max_dsr THEN v_reasons:=array_append(v_reasons,'DEBT_SERVICE_RATIO_EXCEEDED'); END IF;
        IF cardinality(v_reasons)>0 THEN v_affordability_result:='fail';
        ELSE v_reasons:=ARRAY['AFFORDABILITY_SCREEN_PASSED']::TEXT[]; END IF;
      END IF;
      v_decision:=append_loan_application_decision(v_application,'affordability',v_affordability_result,v_reasons,
        jsonb_build_object('monthly_net_income_minor',v_application.monthly_net_income_minor,
          'monthly_existing_debt_minor',v_application.monthly_existing_debt_minor,
          'verified_income_months',v_application.verified_income_months,'estimated_monthly_repayment_minor',v_estimated_monthly,
          'debt_service_ratio_basis_points',v_dsr),
        jsonb_build_object('minimum_verified_income_months',v_min_income_months,
          'maximum_debt_service_ratio_basis_points',v_max_dsr,'effective_annual_cost_basis_points',v_version.effective_annual_cost_basis_points,
          'estimate_day_count_basis',365,'estimate_period_days',30),TRUE,NULL,NULL,p_at);
      IF v_decision.result='fail' THEN
        UPDATE loan_applications SET state='declined',decided_at=p_at,updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
        v_adverse:=create_loan_adverse_review(v_application,v_decision,p_at);
      ELSE
        UPDATE loan_applications SET state='credit_review',updated_at=p_at WHERE id=v_application.id RETURNING * INTO v_application;
      END IF;
    END IF;
  END IF;

  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,v_application.id,'application_submitted',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('final_state',v_application.state,'decision_count',(
      SELECT count(*) FROM loan_application_decisions WHERE application_id=v_application.id)),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_APPLICATION_SCREENED','loan_application',v_application.id::TEXT,
    jsonb_build_object('state',v_application.state,'product_version',v_application.product_version,
      'adverse_review_available',v_adverse.id IS NOT NULL),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',to_jsonb(v_adverse));
END $$;

CREATE OR REPLACE FUNCTION request_loan_adverse_review(
  p_organization UUID,p_actor UUID,p_application UUID,p_reason TEXT,p_evidence JSONB,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_review loan_adverse_reviews; v_event loan_application_events; v_hash TEXT;
BEGIN
  IF length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 1000 OR NOT valid_loan_reference_array(p_evidence)
  THEN RAISE EXCEPTION 'Adverse review request evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,btrim(p_reason),p_evidence::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different adverse review request'; END IF;
    SELECT * INTO v_review FROM loan_adverse_reviews WHERE application_id=v_event.application_id;
    RETURN to_jsonb(v_review);
  END IF;
  SELECT * INTO v_application FROM loan_applications WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_review FROM loan_adverse_reviews WHERE application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id<>p_actor OR v_application.state<>'declined'
    OR v_review.id IS NULL OR v_review.state<>'eligible'
  THEN RAISE EXCEPTION 'Application is not eligible for applicant-requested human review'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_adverse_reviews SET state='requested',requested_by=p_actor,request_reason=btrim(p_reason),
    evidence_references=p_evidence,requested_at=p_at,updated_at=p_at WHERE id=v_review.id RETURNING * INTO v_review;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,'adverse_review_requested',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('adverse_review_id',v_review.id,'evidence_reference_count',jsonb_array_length(p_evidence)),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_ADVERSE_REVIEW_REQUESTED','loan_application',p_application::TEXT,
    jsonb_build_object('adverse_review_id',v_review.id),p_at);
  RETURN to_jsonb(v_review);
END $$;

CREATE OR REPLACE FUNCTION decide_loan_adverse_review(
  p_organization UUID,p_actor UUID,p_application UUID,p_decision TEXT,p_reason TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_review loan_adverse_reviews; v_event loan_application_events;
  v_human loan_application_decisions; v_hash TEXT; v_action TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.review') THEN RAISE EXCEPTION 'Missing financial.loans.review permission'; END IF;
  IF p_decision NOT IN ('uphold','reopen') OR length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 1000
  THEN RAISE EXCEPTION 'Adverse review decision is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_decision,btrim(p_reason)),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different adverse review decision'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    SELECT * INTO v_review FROM loan_adverse_reviews WHERE application_id=v_application.id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',to_jsonb(v_review));
  END IF;
  SELECT * INTO v_application FROM loan_applications WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_review FROM loan_adverse_reviews WHERE application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id=p_actor OR v_application.state<>'declined'
    OR v_review.id IS NULL OR v_review.state<>'requested'
  THEN RAISE EXCEPTION 'Adverse review is not awaiting an independent decision'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  v_human:=append_loan_application_decision(v_application,'human_adverse_review',
    CASE WHEN p_decision='reopen' THEN 'overridden' ELSE 'fail' END,
    ARRAY[CASE WHEN p_decision='reopen' THEN 'ADVERSE_DECISION_REOPENED' ELSE 'ADVERSE_DECISION_UPHELD' END]::TEXT[],
    jsonb_build_object('request_reason',v_review.request_reason,'evidence_references',v_review.evidence_references),
    jsonb_build_object('original_reason_codes',v_review.reason_codes,'notice_version',v_review.notice_version),
    FALSE,p_actor,CASE WHEN p_decision='reopen' THEN btrim(p_reason) ELSE NULL END,p_at);
  UPDATE loan_adverse_reviews SET state=CASE WHEN p_decision='reopen' THEN 'reopened' ELSE 'upheld' END,
    decided_by=p_actor,decision_reason=btrim(p_reason),decided_at=p_at,updated_at=p_at
    WHERE id=v_review.id RETURNING * INTO v_review;
  IF p_decision='reopen' THEN
    UPDATE loan_applications SET state='credit_review',updated_at=p_at WHERE id=p_application RETURNING * INTO v_application;
    v_action:='adverse_review_reopened';
  ELSE v_action:='adverse_review_upheld'; END IF;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,v_action,p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('adverse_review_id',v_review.id,'human_decision_id',v_human.id),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,CASE WHEN p_decision='reopen' THEN 'LOAN_ADVERSE_REVIEW_REOPENED' ELSE 'LOAN_ADVERSE_REVIEW_UPHELD' END,
    'loan_application',p_application::TEXT,jsonb_build_object('adverse_review_id',v_review.id,'state',v_application.state),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',to_jsonb(v_review),'decision',to_jsonb(v_human));
END $$;

CREATE OR REPLACE FUNCTION withdraw_loan_application(
  p_organization UUID,p_actor UUID,p_application UUID,p_reason_code TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_review loan_adverse_reviews; v_event loan_application_events; v_hash TEXT;
BEGIN
  IF COALESCE(p_reason_code,'') !~ '^[A-Z][A-Z0-9_]{2,79}$' THEN RAISE EXCEPTION 'Withdrawal reason code is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_reason_code),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different withdrawal command'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id; RETURN to_jsonb(v_application);
  END IF;
  SELECT * INTO v_application FROM loan_applications WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id<>p_actor
    OR v_application.state NOT IN ('draft','submitted','identity_review','affordability_review','credit_review','declined')
  THEN RAISE EXCEPTION 'Loan application cannot be withdrawn by this actor'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_applications SET state='withdrawn',withdrawn_at=p_at,updated_at=p_at WHERE id=p_application RETURNING * INTO v_application;
  UPDATE loan_adverse_reviews SET state='withdrawn',updated_at=p_at
    WHERE application_id=p_application AND state IN ('eligible','requested','under_review') RETURNING * INTO v_review;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,'application_withdrawn',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('reason_code',p_reason_code),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_APPLICATION_WITHDRAWN','loan_application',p_application::TEXT,
    jsonb_build_object('reason_code',p_reason_code),p_at);
  RETURN to_jsonb(v_application);
END $$;

CREATE OR REPLACE FUNCTION list_loan_applications(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_can_review BOOLEAN;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active')
  THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  v_can_review:=has_financial_permission(p_organization,p_actor,'financial.loans.review');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'application',to_jsonb(application),
      'decisions',(SELECT COALESCE(jsonb_agg(to_jsonb(decision) ORDER BY decision.sequence),'[]'::JSONB)
        FROM loan_application_decisions decision WHERE decision.organization_id=p_organization AND decision.application_id=application.id),
      'adverse_review',(SELECT to_jsonb(review) FROM loan_adverse_reviews review
        WHERE review.organization_id=p_organization AND review.application_id=application.id)
    ) ORDER BY application.created_at DESC)
    FROM loan_applications application
    WHERE application.organization_id=p_organization AND (v_can_review OR application.applicant_user_id=p_actor)),'[]'::JSONB);
END $$;

UPDATE organization_memberships SET permissions=ARRAY(
  SELECT DISTINCT permission FROM unnest(COALESCE(permissions,'{}')||ARRAY[
    'financial.loans.apply_on_behalf','financial.loans.review'
  ]) permission
) WHERE role='owner';

CREATE OR REPLACE FUNCTION provision_loan_application_permissions() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.role='owner' THEN
    IF NOT ('financial.loans.apply_on_behalf'=ANY(COALESCE(NEW.permissions,'{}'))) THEN
      NEW.permissions:=array_append(COALESCE(NEW.permissions,'{}'),'financial.loans.apply_on_behalf'); END IF;
    IF NOT ('financial.loans.review'=ANY(COALESCE(NEW.permissions,'{}'))) THEN
      NEW.permissions:=array_append(COALESCE(NEW.permissions,'{}'),'financial.loans.review'); END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER provision_loan_application_permissions_trigger
  BEFORE INSERT OR UPDATE OF role,permissions ON organization_memberships
  FOR EACH ROW EXECUTE FUNCTION provision_loan_application_permissions();

ALTER TABLE loan_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_application_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_adverse_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_application_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON loan_applications,loan_application_decisions,loan_adverse_reviews,loan_application_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON loan_applications,loan_application_decisions,loan_adverse_reviews,loan_application_events FROM service_role;
GRANT SELECT ON loan_applications,loan_application_decisions,loan_adverse_reviews,loan_application_events TO service_role;
REVOKE ALL ON FUNCTION valid_loan_reference_array(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION append_loan_application_decision(loan_applications,TEXT,TEXT,TEXT[],JSONB,JSONB,BOOLEAN,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_loan_adverse_review(loan_applications,loan_application_decisions,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_loan_application_draft(UUID,UUID,UUID,TEXT,UUID,TEXT,BIGINT,INTEGER,BIGINT,BIGINT,INTEGER,JSONB,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_loan_application(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_loan_adverse_review(UUID,UUID,UUID,TEXT,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_loan_adverse_review(UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION withdraw_loan_application(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_loan_applications(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_loan_application_draft(UUID,UUID,UUID,TEXT,UUID,TEXT,BIGINT,INTEGER,BIGINT,BIGINT,INTEGER,JSONB,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION submit_loan_application(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION request_loan_adverse_review(UUID,UUID,UUID,TEXT,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decide_loan_adverse_review(UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION withdraw_loan_application(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_loan_applications(UUID,UUID) TO service_role;
