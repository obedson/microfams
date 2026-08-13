-- CRD-07: deterministic arrears and delinquency servicing for existing loans.

SET search_path = public, extensions;

ALTER TABLE loan_applications DROP CONSTRAINT loan_applications_state_check;
ALTER TABLE loan_applications ADD CONSTRAINT loan_applications_state_check CHECK (state IN (
  'draft','submitted','identity_review','affordability_review','credit_review',
  'offered','accepted','disbursement_pending','active','paid_off','delinquent','defaulted',
  'declined','withdrawn','cancelled'
));

CREATE TABLE loan_delinquency_assessments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  assessed_on DATE NOT NULL,
  days_past_due INTEGER NOT NULL CHECK (days_past_due>=0),
  principal_arrears_minor BIGINT NOT NULL CHECK (principal_arrears_minor>=0),
  interest_arrears_minor BIGINT NOT NULL CHECK (interest_arrears_minor>=0),
  fee_arrears_minor BIGINT NOT NULL CHECK (fee_arrears_minor>=0),
  total_arrears_minor BIGINT NOT NULL CHECK (
    total_arrears_minor=principal_arrears_minor+interest_arrears_minor+fee_arrears_minor
  ),
  classification TEXT NOT NULL CHECK (classification IN ('current','late','delinquent','defaulted')),
  stage_code TEXT,
  stage_snapshot JSONB NOT NULL CHECK (jsonb_typeof(stage_snapshot)='object'),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash~'^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  assessed_by UUID NOT NULL REFERENCES users(id),
  assessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (contract_id,organization_id) REFERENCES loan_contracts(id,organization_id),
  UNIQUE (organization_id,idempotency_key),
  UNIQUE (organization_id,contract_id,assessed_on),
  UNIQUE (id,organization_id),
  CHECK ((classification='current' AND stage_code IS NULL AND days_past_due=0 AND total_arrears_minor=0)
    OR (classification<>'current' AND stage_code IS NOT NULL AND days_past_due>0 AND total_arrears_minor>0))
);

CREATE INDEX idx_loan_delinquency_assessments_contract
  ON loan_delinquency_assessments(organization_id,contract_id,assessed_on DESC,id DESC);

CREATE OR REPLACE FUNCTION require_loan_delinquency_engine()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_delinquency_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Loan delinquency assessments are immutable outside the servicing engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;

CREATE TRIGGER loan_delinquency_assessments_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON loan_delinquency_assessments
  FOR EACH ROW EXECUTE FUNCTION require_loan_delinquency_engine();

CREATE OR REPLACE FUNCTION assess_loan_delinquency(
  p_organization UUID,p_actor UUID,p_application UUID,p_contract UUID,
  p_assessed_on DATE,p_correlation UUID,p_idempotency_key TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  v_contract loan_contracts;
  v_application loan_applications;
  v_existing loan_delinquency_assessments;
  v_assessment loan_delinquency_assessments;
  v_hash TEXT;
  v_due_principal BIGINT;
  v_due_interest BIGINT;
  v_due_fees BIGINT;
  v_paid_principal BIGINT;
  v_paid_interest BIGINT;
  v_principal_arrears BIGINT;
  v_interest_arrears BIGINT;
  v_fee_arrears BIGINT;
  v_total_arrears BIGINT;
  v_earliest_unpaid_due DATE;
  v_days_past_due INTEGER:=0;
  v_stage JSONB;
  v_classification TEXT:='current';
  v_stage_code TEXT;
  v_contract_state TEXT;
  v_snapshot JSONB;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.loans.service_existing permission';
  END IF;
  IF p_organization IS NULL OR p_actor IS NULL OR p_application IS NULL OR p_contract IS NULL
    OR p_assessed_on IS NULL OR p_correlation IS NULL OR p_idempotency_key IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'Loan delinquency assessment evidence is invalid'; END IF;

  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,
    p_application::TEXT,p_contract::TEXT,p_assessed_on::TEXT,p_correlation::TEXT,
    p_idempotency_key),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization::TEXT||':loan-contract:'||p_contract::TEXT,0
  ));
  SELECT * INTO v_existing FROM loan_delinquency_assessments
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.contract_id<>p_contract OR v_existing.application_id<>p_application
      OR v_existing.request_hash<>v_hash
    THEN RAISE EXCEPTION 'Idempotency key reused with different delinquency facts'; END IF;
    RETURN jsonb_build_object('assessment',to_jsonb(v_existing),'state',
      CASE WHEN v_existing.classification IN ('current','late')
        THEN 'active' ELSE v_existing.classification END);
  END IF;

  SELECT * INTO v_contract FROM loan_contracts
    WHERE id=p_contract AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_contract.id IS NULL OR v_application.id IS NULL
    OR v_contract.state NOT IN ('active','delinquent','defaulted')
  THEN RAISE EXCEPTION 'Loan contract is not eligible for delinquency servicing'; END IF;
  IF v_contract.fees_contractual_minor<>0 THEN
    RAISE EXCEPTION 'Fee-bearing delinquency assessment requires approved fee allocation servicing';
  END IF;

  SELECT COALESCE(SUM(principal_due_minor),0),COALESCE(SUM(interest_due_minor),0),
    COALESCE(SUM(fee_due_minor),0)
  INTO v_due_principal,v_due_interest,v_due_fees
  FROM loan_due_installments
  WHERE organization_id=p_organization AND contract_id=p_contract AND due_on<p_assessed_on;
  SELECT COALESCE(SUM(principal_allocated_minor),0),COALESCE(SUM(interest_allocated_minor),0)
  INTO v_paid_principal,v_paid_interest
  FROM loan_repayments
  WHERE organization_id=p_organization AND contract_id=p_contract AND effective_date<p_assessed_on;

  v_principal_arrears:=GREATEST(v_due_principal-v_paid_principal,0);
  v_interest_arrears:=GREATEST(v_due_interest-v_paid_interest,0);
  v_fee_arrears:=GREATEST(v_due_fees,0);
  v_total_arrears:=v_principal_arrears+v_interest_arrears+v_fee_arrears;
  IF v_total_arrears>0 THEN
    SELECT MIN(due_on) INTO v_earliest_unpaid_due
    FROM (
      SELECT due_on,SUM(total_due_minor) OVER (ORDER BY due_on,sequence) cumulative_due
      FROM loan_due_installments
      WHERE organization_id=p_organization AND contract_id=p_contract AND due_on<p_assessed_on
    ) due
    WHERE due.cumulative_due>v_paid_principal+v_paid_interest;
    v_days_past_due:=p_assessed_on-v_earliest_unpaid_due;
    SELECT stage INTO v_stage
    FROM jsonb_array_elements(v_application.product_rule_snapshot->'version'->'delinquency_stages') stage
    WHERE (stage->>'startsAfterDays')::INTEGER<=v_days_past_due
    ORDER BY (stage->>'startsAfterDays')::INTEGER DESC LIMIT 1;
    IF v_stage IS NULL THEN
      RAISE EXCEPTION 'Product delinquency stages do not classify the overdue balance';
    END IF;
    v_classification:=v_stage->>'classification';
    v_stage_code:=v_stage->>'code';
  END IF;

  v_contract_state:=CASE
    WHEN v_classification='defaulted' THEN 'defaulted'
    WHEN v_classification='delinquent' THEN 'delinquent'
    ELSE 'active'
  END;
  v_snapshot:=jsonb_build_object('version','CRD-07.DELINQUENCY.1',
    'assessedOn',p_assessed_on,'earliestUnpaidDueOn',v_earliest_unpaid_due,
    'daysPastDue',v_days_past_due,'classification',v_classification,
    'stage',v_stage,'arrears',jsonb_build_object('principalMinor',v_principal_arrears,
      'interestMinor',v_interest_arrears,'feeMinor',v_fee_arrears,'totalMinor',v_total_arrears),
    'paidBeforeAssessment',jsonb_build_object('principalMinor',v_paid_principal,
      'interestMinor',v_paid_interest));
  PERFORM set_config('microfams.loan_delinquency_engine','on',TRUE);
  INSERT INTO loan_delinquency_assessments(organization_id,application_id,contract_id,
    assessed_on,days_past_due,principal_arrears_minor,interest_arrears_minor,
    fee_arrears_minor,total_arrears_minor,classification,stage_code,stage_snapshot,
    idempotency_key,request_hash,correlation_id,assessed_by)
  VALUES(p_organization,p_application,p_contract,p_assessed_on,v_days_past_due,
    v_principal_arrears,v_interest_arrears,v_fee_arrears,v_total_arrears,
    v_classification,v_stage_code,v_snapshot,p_idempotency_key,v_hash,p_correlation,p_actor)
  RETURNING * INTO v_assessment;

  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_contracts SET state=v_contract_state WHERE id=p_contract;
  UPDATE loan_applications SET state=v_contract_state,updated_at=NOW()
    WHERE id=p_application AND organization_id=p_organization;
  WITH allocation AS (
    SELECT id,due_on,total_due_minor,
      SUM(total_due_minor) OVER (ORDER BY due_on,sequence,id) AS cumulative_due
    FROM loan_due_installments
    WHERE organization_id=p_organization AND contract_id=p_contract
  )
  UPDATE loan_due_installments installment SET state=CASE
    WHEN allocation.cumulative_due<=v_paid_principal+v_paid_interest THEN 'paid'
    WHEN allocation.cumulative_due-allocation.total_due_minor<v_paid_principal+v_paid_interest
      THEN 'partially_paid'
    WHEN allocation.due_on<p_assessed_on THEN 'overdue'
    ELSE 'due' END
  FROM allocation WHERE installment.id=allocation.id;

  INSERT INTO organization_audit_log(organization_id,actor_id,action,
    resource_type,resource_id,after_value)
  VALUES(p_organization,p_actor,'LOAN_DELINQUENCY_ASSESSED','loan_delinquency_assessment',
    v_assessment.id::TEXT,jsonb_build_object('contract_id',p_contract,
      'classification',v_classification,'days_past_due',v_days_past_due,
      'total_arrears_minor',v_total_arrears));
  RETURN jsonb_build_object('assessment',to_jsonb(v_assessment),'state',v_contract_state);
END $$;

REVOKE INSERT,UPDATE,DELETE ON loan_delinquency_assessments FROM service_role;
GRANT SELECT ON loan_delinquency_assessments TO service_role;
REVOKE ALL ON FUNCTION assess_loan_delinquency(UUID,UUID,UUID,UUID,DATE,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION assess_loan_delinquency(UUID,UUID,UUID,UUID,DATE,UUID,TEXT) TO service_role;

ALTER TABLE loan_delinquency_assessments ENABLE ROW LEVEL SECURITY;
