-- CRD-03: independent manual credit review, immutable offer versions,
-- exact borrower acceptance, expiry, and pre-acceptance withdrawal.

SET search_path = public, extensions;

ALTER TABLE loan_applications DROP CONSTRAINT loan_applications_state_check;
ALTER TABLE loan_applications ADD CONSTRAINT loan_applications_state_check CHECK (state IN (
  'draft','submitted','identity_review','affordability_review','credit_review',
  'offered','accepted','declined','withdrawn','cancelled'
));

ALTER TABLE loan_application_decisions DROP CONSTRAINT loan_application_decisions_stage_check;
ALTER TABLE loan_application_decisions ADD CONSTRAINT loan_application_decisions_stage_check CHECK (
  stage IN ('eligibility','identity','affordability','credit_review','human_adverse_review')
);
ALTER TABLE loan_application_decisions ADD COLUMN review_reason TEXT
  CHECK (review_reason IS NULL OR length(btrim(review_reason)) BETWEEN 12 AND 1000);

ALTER TABLE loan_application_events DROP CONSTRAINT loan_application_events_action_check;
ALTER TABLE loan_application_events ADD CONSTRAINT loan_application_events_action_check CHECK (action IN (
  'application_created','application_submitted','adverse_review_requested',
  'adverse_review_upheld','adverse_review_reopened','application_withdrawn',
  'credit_review_declined','offer_issued','offer_revised','offer_accepted','offer_expired'
));

CREATE OR REPLACE FUNCTION valid_loan_decision_codes(p_codes TEXT[]) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT p_codes IS NOT NULL
    AND cardinality(p_codes) BETWEEN 1 AND 20
    AND cardinality(p_codes) = (SELECT count(DISTINCT code) FROM unnest(p_codes) code)
    AND NOT EXISTS (
      SELECT 1 FROM unnest(p_codes) code
      WHERE code !~ '^[A-Z][A-Z0-9_]{2,79}$'
    );
$$;

CREATE OR REPLACE FUNCTION valid_loan_condition_codes(p_codes TEXT[]) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT p_codes IS NOT NULL
    AND cardinality(p_codes) <= 20
    AND cardinality(p_codes) = (SELECT count(DISTINCT code) FROM unnest(p_codes) code)
    AND NOT EXISTS (
      SELECT 1 FROM unnest(p_codes) code
      WHERE code !~ '^[A-Z][A-Z0-9_]{2,79}$'
    );
$$;

CREATE OR REPLACE FUNCTION calculate_loan_offer_fee_total(p_principal_minor BIGINT,p_fees JSONB)
RETURNS BIGINT LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT COALESCE(SUM(CASE
    WHEN fee->>'timing' = 'delinquency' THEN 0
    WHEN fee->>'calculation' = 'fixed' THEN (fee->>'amountMinor')::BIGINT
    ELSE CEIL(p_principal_minor::NUMERIC*(fee->>'rateBasisPoints')::NUMERIC/10000)::BIGINT
  END),0)::BIGINT
  FROM jsonb_array_elements(p_fees) fee;
$$;

CREATE TABLE loan_offers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  state TEXT NOT NULL DEFAULT 'offered' CHECK (state IN (
    'offered','accepted','expired','superseded','withdrawn'
  )),
  review_decision_id UUID NOT NULL,
  supersedes_offer_id UUID,
  principal_minor BIGINT NOT NULL CHECK (principal_minor > 0),
  tenor_days INTEGER NOT NULL CHECK (tenor_days > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  repayment_frequency TEXT NOT NULL CHECK (
    repayment_frequency IN ('weekly','fortnightly','monthly','quarterly','bullet')
  ),
  interest_method TEXT NOT NULL CHECK (
    interest_method IN ('reducing_balance','flat','simple','zero_interest')
  ),
  nominal_annual_rate_basis_points INTEGER NOT NULL CHECK (
    nominal_annual_rate_basis_points BETWEEN 0 AND 100000
  ),
  apr_basis_points INTEGER NOT NULL CHECK (
    apr_basis_points BETWEEN nominal_annual_rate_basis_points AND 100000
  ),
  effective_annual_cost_basis_points INTEGER NOT NULL CHECK (
    effective_annual_cost_basis_points BETWEEN apr_basis_points AND 100000
  ),
  total_interest_minor BIGINT NOT NULL CHECK (total_interest_minor >= 0),
  total_fees_minor BIGINT NOT NULL CHECK (total_fees_minor >= 0),
  total_repayable_minor BIGINT NOT NULL,
  fees JSONB NOT NULL CHECK (valid_loan_fee_rules(fees)),
  grace_period_days INTEGER NOT NULL CHECK (grace_period_days >= 0),
  collateral_rules JSONB NOT NULL CHECK (jsonb_typeof(collateral_rules) = 'object'),
  guarantee_rules JSONB NOT NULL CHECK (jsonb_typeof(guarantee_rules) = 'object'),
  repayment_allocation_order TEXT[] NOT NULL CHECK (
    cardinality(repayment_allocation_order) = 5
    AND repayment_allocation_order @> ARRAY[
      'statutory_charges','collection_costs','penalties','accrued_interest','principal'
    ]::TEXT[]
  ),
  penalty_compounding_allowed BOOLEAN NOT NULL,
  penalty_compounding_legal_basis TEXT,
  condition_codes TEXT[] NOT NULL CHECK (valid_loan_condition_codes(condition_codes)),
  disclosure_version TEXT NOT NULL CHECK (length(btrim(disclosure_version)) BETWEEN 1 AND 80),
  disclosure_content_hash VARCHAR(64) NOT NULL CHECK (disclosure_content_hash ~ '^[a-f0-9]{64}$'),
  terms_snapshot JSONB NOT NULL CHECK (jsonb_typeof(terms_snapshot) = 'object'),
  offer_hash VARCHAR(64) NOT NULL CHECK (offer_hash ~ '^[a-f0-9]{64}$'),
  issued_by UUID NOT NULL REFERENCES users(id),
  issued_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  accepted_by UUID REFERENCES users(id),
  acceptance_version TEXT,
  acceptance_content_hash VARCHAR(64),
  accepted_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (application_id, organization_id) REFERENCES loan_applications(id, organization_id),
  FOREIGN KEY (review_decision_id, organization_id)
    REFERENCES loan_application_decisions(id, organization_id),
  FOREIGN KEY (supersedes_offer_id, organization_id) REFERENCES loan_offers(id, organization_id),
  UNIQUE (organization_id, application_id, version),
  UNIQUE (id, organization_id),
  CHECK (total_repayable_minor = principal_minor + total_interest_minor + total_fees_minor),
  CHECK (expires_at > issued_at),
  CHECK ((penalty_compounding_allowed
      AND length(btrim(penalty_compounding_legal_basis)) BETWEEN 12 AND 500)
    OR (NOT penalty_compounding_allowed AND penalty_compounding_legal_basis IS NULL)),
  CHECK ((state = 'accepted'
      AND accepted_by IS NOT NULL
      AND length(btrim(acceptance_version)) BETWEEN 1 AND 80
      AND acceptance_content_hash ~ '^[a-f0-9]{64}$'
      AND accepted_at IS NOT NULL)
    OR (state <> 'accepted'
      AND accepted_by IS NULL
      AND acceptance_version IS NULL
      AND acceptance_content_hash IS NULL
      AND accepted_at IS NULL))
);
CREATE UNIQUE INDEX uq_current_loan_offer
  ON loan_offers(organization_id, application_id)
  WHERE state IN ('offered','accepted');
CREATE INDEX idx_loan_offer_expiry
  ON loan_offers(organization_id, expires_at)
  WHERE state = 'offered';

ALTER TABLE loan_application_events ADD COLUMN offer_id UUID;
ALTER TABLE loan_application_events ADD CONSTRAINT loan_application_events_offer_fk
  FOREIGN KEY (offer_id, organization_id) REFERENCES loan_offers(id, organization_id);

CREATE TRIGGER loan_offers_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_offers
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();

CREATE OR REPLACE FUNCTION issue_loan_offer(
  p_organization UUID,
  p_actor UUID,
  p_application UUID,
  p_principal_minor BIGINT,
  p_tenor_days INTEGER,
  p_total_interest_minor BIGINT,
  p_total_fees_minor BIGINT,
  p_total_repayable_minor BIGINT,
  p_condition_codes TEXT[],
  p_disclosure_version TEXT,
  p_disclosure_hash TEXT,
  p_expires_at TIMESTAMPTZ,
  p_reason_codes TEXT[],
  p_review_reason TEXT,
  p_idempotency_key TEXT,
  p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_application loan_applications;
  v_version loan_product_versions;
  v_previous loan_offers;
  v_offer loan_offers;
  v_decision loan_application_decisions;
  v_event loan_application_events;
  v_snapshot JSONB;
  v_hash TEXT;
  v_offer_hash TEXT;
  v_sequence INTEGER;
  v_offer_version INTEGER;
  v_action TEXT;
  v_expected_fees BIGINT;
  v_interest_cap BIGINT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.review') THEN
    RAISE EXCEPTION 'Missing financial.loans.review permission';
  END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR p_principal_minor <= 0 OR p_tenor_days <= 0
    OR p_total_interest_minor < 0 OR p_total_fees_minor < 0
    OR p_total_repayable_minor <> p_principal_minor + p_total_interest_minor + p_total_fees_minor
    OR NOT valid_loan_condition_codes(p_condition_codes)
    OR NOT valid_loan_decision_codes(p_reason_codes)
    OR length(btrim(COALESCE(p_review_reason,''))) NOT BETWEEN 12 AND 1000
    OR length(btrim(COALESCE(p_disclosure_version,''))) NOT BETWEEN 1 AND 80
    OR COALESCE(p_disclosure_hash,'') !~ '^[a-f0-9]{64}$'
    OR p_expires_at <= p_at + INTERVAL '1 hour'
    OR p_expires_at > p_at + INTERVAL '90 days'
  THEN RAISE EXCEPTION 'Loan offer facts are invalid'; END IF;

  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,
    p_principal_minor::TEXT,p_tenor_days::TEXT,p_total_interest_minor::TEXT,p_total_fees_minor::TEXT,
    p_total_repayable_minor::TEXT,array_to_string(p_condition_codes,','),p_disclosure_version,p_disclosure_hash,
    floor(extract(epoch FROM p_expires_at)*1000000)::BIGINT::TEXT,
    array_to_string(p_reason_codes,','),btrim(p_review_reason)),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash OR v_event.offer_id IS NULL THEN
      RAISE EXCEPTION 'Idempotency key reused with different offer facts'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    SELECT * INTO v_offer FROM loan_offers WHERE id=v_event.offer_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer));
  END IF;

  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.state NOT IN ('credit_review','offered')
    OR v_application.applicant_user_id=p_actor
  THEN RAISE EXCEPTION 'Application is not awaiting an independent credit offer'; END IF;
  SELECT * INTO v_version FROM loan_product_versions
    WHERE id=v_application.product_version_id AND organization_id=p_organization;
  IF v_version.id IS NULL THEN RAISE EXCEPTION 'Pinned loan product version is unavailable'; END IF;
  IF p_principal_minor > v_application.requested_principal_minor
    OR p_principal_minor NOT BETWEEN v_version.minimum_principal_minor AND v_version.maximum_principal_minor
    OR p_tenor_days NOT BETWEEN v_version.minimum_tenor_days AND v_version.maximum_tenor_days
    OR btrim(p_disclosure_version)<>v_version.disclosure_version
    OR p_disclosure_hash<>v_version.disclosure_content_hash
  THEN RAISE EXCEPTION 'Offer is outside the application or pinned product terms'; END IF;
  v_expected_fees:=calculate_loan_offer_fee_total(p_principal_minor,v_version.fees);
  v_interest_cap:=CEIL(p_principal_minor::NUMERIC*v_version.nominal_annual_rate_basis_points::NUMERIC
    *p_tenor_days::NUMERIC/3650000::NUMERIC)::BIGINT;
  IF p_total_fees_minor<>v_expected_fees
    OR (v_version.interest_method='zero_interest' AND p_total_interest_minor<>0)
    OR (v_version.interest_method IN ('flat','simple') AND p_total_interest_minor<>v_interest_cap)
    OR (v_version.interest_method='reducing_balance'
      AND (p_total_interest_minor<=0 OR p_total_interest_minor>v_interest_cap))
  THEN RAISE EXCEPTION 'Offer economics do not match the pinned product rules'; END IF;

  IF v_application.state='offered' THEN
    SELECT * INTO v_previous FROM loan_offers
      WHERE organization_id=p_organization AND application_id=p_application AND state='offered' FOR UPDATE;
    IF v_previous.id IS NULL THEN RAISE EXCEPTION 'Current offered version was not found'; END IF;
  END IF;

  v_snapshot:=jsonb_build_object(
    'applicationId',v_application.id,'productId',v_application.product_id,
    'productVersionId',v_application.product_version_id,'productVersion',v_application.product_version,
    'principalMinor',p_principal_minor,'tenorDays',p_tenor_days,'currency',v_application.currency,
    'repaymentFrequency',v_version.repayment_frequency,'interestMethod',v_version.interest_method,
    'nominalAnnualRateBasisPoints',v_version.nominal_annual_rate_basis_points,
    'aprBasisPoints',v_version.apr_basis_points,
    'effectiveAnnualCostBasisPoints',v_version.effective_annual_cost_basis_points,
    'totalInterestMinor',p_total_interest_minor,'totalFeesMinor',p_total_fees_minor,
    'totalRepayableMinor',p_total_repayable_minor,'fees',v_version.fees,
    'gracePeriodDays',v_version.grace_period_days,'collateralRules',v_version.collateral_rules,
    'guaranteeRules',v_version.guarantee_rules,
    'repaymentAllocationOrder',to_jsonb(v_version.repayment_allocation_order),
    'penaltyCompoundingAllowed',v_version.penalty_compounding_allowed,
    'penaltyCompoundingLegalBasis',v_version.penalty_compounding_legal_basis,
    'conditionCodes',to_jsonb(p_condition_codes),'disclosureVersion',v_version.disclosure_version,
    'disclosureContentHash',v_version.disclosure_content_hash,
    'expiresAtEpochMicroseconds',floor(extract(epoch FROM p_expires_at)*1000000)::BIGINT
  );
  v_offer_hash:=encode(digest(convert_to(v_snapshot::TEXT,'UTF8'),'sha256'),'hex');
  SELECT COALESCE(MAX(sequence),0)+1 INTO v_sequence FROM loan_application_decisions
    WHERE organization_id=p_organization AND application_id=p_application;
  SELECT COALESCE(MAX(version),0)+1 INTO v_offer_version FROM loan_offers
    WHERE organization_id=p_organization AND application_id=p_application;

  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_application_decisions(organization_id,application_id,sequence,stage,model_code,model_version,
    result,reason_codes,input_facts,rules_snapshot,automated,reviewer_id,review_reason,created_at)
  VALUES(p_organization,p_application,v_sequence,'credit_review','human_credit_review','CRD-03.HUMAN.1',
    'pass',p_reason_codes,jsonb_build_object('offer_terms',v_snapshot),v_application.product_rule_snapshot,
    FALSE,p_actor,btrim(p_review_reason),p_at)
  RETURNING * INTO v_decision;
  IF v_previous.id IS NOT NULL THEN
    UPDATE loan_offers SET state='superseded',updated_at=p_at WHERE id=v_previous.id;
    v_action:='offer_revised';
  ELSE v_action:='offer_issued'; END IF;
  INSERT INTO loan_offers(organization_id,application_id,version,review_decision_id,supersedes_offer_id,
    principal_minor,tenor_days,currency,repayment_frequency,interest_method,nominal_annual_rate_basis_points,
    apr_basis_points,effective_annual_cost_basis_points,total_interest_minor,total_fees_minor,total_repayable_minor,
    fees,grace_period_days,collateral_rules,guarantee_rules,repayment_allocation_order,
    penalty_compounding_allowed,penalty_compounding_legal_basis,condition_codes,disclosure_version,
    disclosure_content_hash,terms_snapshot,offer_hash,issued_by,issued_at,expires_at,updated_at)
  VALUES(p_organization,p_application,v_offer_version,v_decision.id,v_previous.id,p_principal_minor,p_tenor_days,
    v_application.currency,v_version.repayment_frequency,v_version.interest_method,
    v_version.nominal_annual_rate_basis_points,v_version.apr_basis_points,
    v_version.effective_annual_cost_basis_points,p_total_interest_minor,p_total_fees_minor,p_total_repayable_minor,
    v_version.fees,v_version.grace_period_days,v_version.collateral_rules,v_version.guarantee_rules,
    v_version.repayment_allocation_order,v_version.penalty_compounding_allowed,
    v_version.penalty_compounding_legal_basis,p_condition_codes,v_version.disclosure_version,
    v_version.disclosure_content_hash,v_snapshot,v_offer_hash,p_actor,p_at,p_expires_at,p_at)
  RETURNING * INTO v_offer;
  UPDATE loan_applications SET state='offered',decided_at=p_at,updated_at=p_at
    WHERE id=p_application RETURNING * INTO v_application;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,v_offer.id,v_action,p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('offer_version',v_offer.version,'offer_hash',v_offer.offer_hash,
      'supersedes_offer_id',v_previous.id,'review_decision_id',v_decision.id),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,CASE WHEN v_previous.id IS NULL THEN 'LOAN_OFFER_ISSUED' ELSE 'LOAN_OFFER_REVISED' END,
    'loan_offer',v_offer.id::TEXT,jsonb_build_object('application_id',p_application,
      'version',v_offer.version,'expires_at',v_offer.expires_at),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer),
    'decision',to_jsonb(v_decision));
END $$;

CREATE OR REPLACE FUNCTION decline_loan_application(
  p_organization UUID,p_actor UUID,p_application UUID,p_reason_codes TEXT[],p_review_reason TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_application loan_applications;
  v_decision loan_application_decisions;
  v_review loan_adverse_reviews;
  v_event loan_application_events;
  v_hash TEXT;
  v_sequence INTEGER;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.review') THEN
    RAISE EXCEPTION 'Missing financial.loans.review permission'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR NOT valid_loan_decision_codes(p_reason_codes)
    OR length(btrim(COALESCE(p_review_reason,''))) NOT BETWEEN 12 AND 1000
  THEN RAISE EXCEPTION 'Credit decline evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,
    array_to_string(p_reason_codes,','),btrim(p_review_reason),'decline'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different decline facts'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    SELECT * INTO v_review FROM loan_adverse_reviews
      WHERE organization_id=p_organization AND application_id=v_event.application_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',to_jsonb(v_review));
  END IF;
  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.state<>'credit_review'
    OR v_application.applicant_user_id=p_actor
  THEN RAISE EXCEPTION 'Application is not awaiting an independent credit decision'; END IF;
  SELECT * INTO v_review FROM loan_adverse_reviews
    WHERE organization_id=p_organization AND application_id=p_application FOR UPDATE;
  IF v_review.id IS NOT NULL AND v_review.state<>'reopened' THEN
    RAISE EXCEPTION 'Prior adverse review is not resolved for a new credit decision'; END IF;
  SELECT COALESCE(MAX(sequence),0)+1 INTO v_sequence FROM loan_application_decisions
    WHERE organization_id=p_organization AND application_id=p_application;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_application_decisions(organization_id,application_id,sequence,stage,model_code,model_version,
    result,reason_codes,input_facts,rules_snapshot,automated,reviewer_id,review_reason,created_at)
  VALUES(p_organization,p_application,v_sequence,'credit_review','human_credit_review','CRD-03.HUMAN.1',
    'fail',p_reason_codes,jsonb_build_object('application_state',v_application.state),
    v_application.product_rule_snapshot,FALSE,p_actor,btrim(p_review_reason),p_at)
  RETURNING * INTO v_decision;
  UPDATE loan_applications SET state='declined',decided_at=p_at,updated_at=p_at
    WHERE id=p_application RETURNING * INTO v_application;
  IF v_review.id IS NULL THEN
    INSERT INTO loan_adverse_reviews(organization_id,application_id,adverse_decision_id,state,reason_codes,
      notice_version,notice_content_hash,issued_at,created_at,updated_at)
    VALUES(p_organization,p_application,v_decision.id,'eligible',p_reason_codes,'CRD-03.ADVERSE.1',
      'd4aa7309b172aa88fdbc15170d77dc201a8200ca43e684cd1e4c4409c57b3291',p_at,p_at,p_at)
    RETURNING * INTO v_review;
  ELSE
    UPDATE loan_adverse_reviews SET adverse_decision_id=v_decision.id,state='eligible',reason_codes=p_reason_codes,
      notice_version='CRD-03.ADVERSE.1',
      notice_content_hash='d4aa7309b172aa88fdbc15170d77dc201a8200ca43e684cd1e4c4409c57b3291',
      issued_at=p_at,requested_by=NULL,request_reason=NULL,evidence_references='[]'::JSONB,requested_at=NULL,
      decided_by=NULL,decision_reason=NULL,decided_at=NULL,updated_at=p_at
      WHERE id=v_review.id RETURNING * INTO v_review;
  END IF;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,
    request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,'credit_review_declined',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('decision_id',v_decision.id,'adverse_review_id',v_review.id,
      'notice_version',v_review.notice_version,'notice_content_hash',v_review.notice_content_hash),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_CREDIT_REVIEW_DECLINED','loan_application',p_application::TEXT,
    jsonb_build_object('decision_id',v_decision.id,'adverse_review_id',v_review.id),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'adverse_review',to_jsonb(v_review),
    'decision',to_jsonb(v_decision));
END $$;

CREATE OR REPLACE FUNCTION accept_loan_offer(
  p_organization UUID,p_actor UUID,p_application UUID,p_offer UUID,p_expected_offer_hash TEXT,
  p_acceptance_version TEXT,p_acceptance_hash TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_offer loan_offers; v_event loan_application_events; v_hash TEXT;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR COALESCE(p_expected_offer_hash,'') !~ '^[a-f0-9]{64}$'
    OR length(btrim(COALESCE(p_acceptance_version,''))) NOT BETWEEN 1 AND 80
    OR COALESCE(p_acceptance_hash,'') !~ '^[a-f0-9]{64}$'
  THEN RAISE EXCEPTION 'Loan offer acceptance evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_offer::TEXT,
    p_expected_offer_hash,btrim(p_acceptance_version),p_acceptance_hash),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash OR v_event.offer_id<>p_offer THEN
      RAISE EXCEPTION 'Idempotency key reused with different acceptance facts'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    SELECT * INTO v_offer FROM loan_offers WHERE id=v_event.offer_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer));
  END IF;
  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE id=p_offer AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id<>p_actor OR v_application.state<>'offered'
    OR v_offer.id IS NULL OR v_offer.state<>'offered'
  THEN RAISE EXCEPTION 'Offer is not available to this applicant'; END IF;
  IF v_application.borrower_type<>'individual'
    AND NOT has_financial_permission(p_organization,p_actor,'financial.loans.apply_on_behalf')
  THEN RAISE EXCEPTION 'Borrower representative authority is no longer active'; END IF;
  IF v_offer.expires_at<=p_at THEN RAISE EXCEPTION 'Loan offer has expired'; END IF;
  IF v_offer.offer_hash<>p_expected_offer_hash THEN RAISE EXCEPTION 'Accepted offer hash does not match'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_offers SET state='accepted',accepted_by=p_actor,acceptance_version=btrim(p_acceptance_version),
    acceptance_content_hash=p_acceptance_hash,accepted_at=p_at,updated_at=p_at
    WHERE id=p_offer RETURNING * INTO v_offer;
  UPDATE loan_applications SET state='accepted',updated_at=p_at
    WHERE id=p_application RETURNING * INTO v_application;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,p_offer,'offer_accepted',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('offer_version',v_offer.version,'offer_hash',v_offer.offer_hash,
      'acceptance_version',v_offer.acceptance_version,'acceptance_content_hash',v_offer.acceptance_content_hash),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_OFFER_ACCEPTED','loan_offer',p_offer::TEXT,
    jsonb_build_object('application_id',p_application,'version',v_offer.version),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer));
END $$;

CREATE OR REPLACE FUNCTION expire_loan_offer(
  p_organization UUID,p_actor UUID,p_application UUID,p_offer UUID,p_reason_code TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_offer loan_offers; v_event loan_application_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.review') THEN
    RAISE EXCEPTION 'Missing financial.loans.review permission'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR COALESCE(p_reason_code,'') !~ '^[A-Z][A-Z0-9_]{2,79}$'
  THEN RAISE EXCEPTION 'Offer expiry evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_offer::TEXT,
    p_reason_code,'expire'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash OR v_event.offer_id<>p_offer THEN
      RAISE EXCEPTION 'Idempotency key reused with different expiry facts'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id;
    SELECT * INTO v_offer FROM loan_offers WHERE id=v_event.offer_id;
    RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer));
  END IF;
  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE id=p_offer AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id=p_actor OR v_application.state<>'offered'
    OR v_offer.id IS NULL OR v_offer.state<>'offered' OR v_offer.expires_at>p_at
  THEN RAISE EXCEPTION 'Offer is not eligible for independent expiry servicing'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_offers SET state='expired',updated_at=p_at WHERE id=p_offer RETURNING * INTO v_offer;
  UPDATE loan_applications SET state='credit_review',updated_at=p_at
    WHERE id=p_application RETURNING * INTO v_application;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,p_offer,'offer_expired',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('offer_version',v_offer.version,'reason_code',p_reason_code),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_OFFER_EXPIRED','loan_offer',p_offer::TEXT,
    jsonb_build_object('application_id',p_application,'reason_code',p_reason_code),p_at);
  RETURN jsonb_build_object('application',to_jsonb(v_application),'offer',to_jsonb(v_offer));
END $$;

CREATE OR REPLACE FUNCTION withdraw_loan_application(
  p_organization UUID,p_actor UUID,p_application UUID,p_reason_code TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_application loan_applications; v_review loan_adverse_reviews; v_offer loan_offers;
  v_event loan_application_events; v_hash TEXT;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    OR COALESCE(p_reason_code,'') !~ '^[A-Z][A-Z0-9_]{2,79}$'
  THEN RAISE EXCEPTION 'Withdrawal command evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_reason_code),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different withdrawal command'; END IF;
    SELECT * INTO v_application FROM loan_applications WHERE id=v_event.application_id; RETURN to_jsonb(v_application);
  END IF;
  SELECT * INTO v_application FROM loan_applications WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.applicant_user_id<>p_actor
    OR v_application.state NOT IN ('draft','submitted','identity_review','affordability_review','credit_review','offered','declined')
  THEN RAISE EXCEPTION 'Loan application cannot be withdrawn by this actor'; END IF;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_applications SET state='withdrawn',withdrawn_at=p_at,updated_at=p_at WHERE id=p_application RETURNING * INTO v_application;
  UPDATE loan_adverse_reviews SET state='withdrawn',updated_at=p_at
    WHERE application_id=p_application AND state IN ('eligible','requested','under_review') RETURNING * INTO v_review;
  UPDATE loan_offers SET state='withdrawn',updated_at=p_at
    WHERE application_id=p_application AND state='offered' RETURNING * INTO v_offer;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,v_offer.id,'application_withdrawn',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('reason_code',p_reason_code,'offer_id',v_offer.id),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_APPLICATION_WITHDRAWN','loan_application',p_application::TEXT,
    jsonb_build_object('reason_code',p_reason_code,'offer_id',v_offer.id),p_at);
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
        WHERE review.organization_id=p_organization AND review.application_id=application.id),
      'offers',(SELECT COALESCE(jsonb_agg(to_jsonb(offer) ORDER BY offer.version),'[]'::JSONB)
        FROM loan_offers offer WHERE offer.organization_id=p_organization AND offer.application_id=application.id)
    ) ORDER BY application.created_at DESC)
    FROM loan_applications application
    WHERE application.organization_id=p_organization AND (v_can_review OR application.applicant_user_id=p_actor)),'[]'::JSONB);
END $$;

ALTER TABLE loan_offers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON loan_offers FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON loan_offers FROM service_role;
GRANT SELECT ON loan_offers TO service_role;
REVOKE ALL ON FUNCTION valid_loan_decision_codes(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION valid_loan_condition_codes(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION calculate_loan_offer_fee_total(BIGINT,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION issue_loan_offer(UUID,UUID,UUID,BIGINT,INTEGER,BIGINT,BIGINT,BIGINT,TEXT[],TEXT,TEXT,TIMESTAMPTZ,TEXT[],TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decline_loan_application(UUID,UUID,UUID,TEXT[],TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_loan_offer(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_loan_offer(UUID,UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_loan_offer(UUID,UUID,UUID,BIGINT,INTEGER,BIGINT,BIGINT,BIGINT,TEXT[],TEXT,TEXT,TIMESTAMPTZ,TEXT[],TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decline_loan_application(UUID,UUID,UUID,TEXT[],TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION accept_loan_offer(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION expire_loan_offer(UUID,UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
