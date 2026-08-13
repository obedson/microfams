-- CRD-09: maker-checker restructuring of outstanding zero-interest loans.

SET search_path = public, extensions;

ALTER TABLE loan_applications DROP CONSTRAINT loan_applications_state_check;
ALTER TABLE loan_applications ADD CONSTRAINT loan_applications_state_check CHECK (state IN (
  'draft','submitted','identity_review','affordability_review','credit_review',
  'offered','accepted','disbursement_pending','active','paid_off','delinquent','defaulted',
  'restructured','written_off','declined','withdrawn','cancelled'
));

CREATE TABLE loan_restructures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','approved','rejected')),
  effective_date DATE NOT NULL,
  first_due_date DATE NOT NULL CHECK (first_due_date>=effective_date),
  installment_count INTEGER NOT NULL CHECK (installment_count BETWEEN 1 AND 600),
  principal_outstanding_minor BIGINT NOT NULL CHECK (principal_outstanding_minor>0),
  reason_code TEXT NOT NULL CHECK (reason_code~'^[A-Z][A-Z0-9_]{2,39}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 12 AND 500),
  evidence_references JSONB NOT NULL CHECK (
    jsonb_typeof(evidence_references)='array' AND jsonb_array_length(evidence_references)>0
  ),
  prior_schedule_snapshot JSONB NOT NULL CHECK (jsonb_typeof(prior_schedule_snapshot)='object'),
  proposed_schedule_snapshot JSONB NOT NULL CHECK (jsonb_typeof(proposed_schedule_snapshot)='object'),
  proposed_schedule_hash VARCHAR(64) NOT NULL CHECK (proposed_schedule_hash~'^[a-f0-9]{64}$'),
  proposed_by UUID NOT NULL REFERENCES users(id),
  proposed_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id),
  review_reason TEXT,
  reviewed_at TIMESTAMPTZ,
  proposal_idempotency_key TEXT NOT NULL CHECK (length(proposal_idempotency_key) BETWEEN 8 AND 160),
  proposal_request_hash VARCHAR(64) NOT NULL CHECK (proposal_request_hash~'^[a-f0-9]{64}$'),
  proposal_correlation_id UUID NOT NULL,
  review_idempotency_key TEXT CHECK (review_idempotency_key IS NULL OR length(review_idempotency_key) BETWEEN 8 AND 160),
  review_request_hash VARCHAR(64) CHECK (review_request_hash IS NULL OR review_request_hash~'^[a-f0-9]{64}$'),
  review_correlation_id UUID,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (contract_id,organization_id) REFERENCES loan_contracts(id,organization_id),
  UNIQUE (organization_id,proposal_idempotency_key),
  UNIQUE (id,organization_id),
  CHECK ((state='proposed' AND reviewed_by IS NULL AND review_reason IS NULL AND reviewed_at IS NULL
      AND review_idempotency_key IS NULL AND review_request_hash IS NULL AND review_correlation_id IS NULL)
    OR (state IN ('approved','rejected') AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by
      AND review_reason IS NOT NULL AND reviewed_at IS NOT NULL AND review_idempotency_key IS NOT NULL
      AND review_request_hash IS NOT NULL AND review_correlation_id IS NOT NULL))
);

CREATE TABLE loan_restructure_installments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  restructure_id UUID NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 600),
  due_on DATE NOT NULL,
  principal_due_minor BIGINT NOT NULL CHECK (principal_due_minor>0),
  FOREIGN KEY (restructure_id,organization_id) REFERENCES loan_restructures(id,organization_id),
  UNIQUE (organization_id,restructure_id,sequence),
  UNIQUE (id,organization_id)
);

ALTER TABLE loan_due_installments ALTER COLUMN contractual_installment_id DROP NOT NULL;
ALTER TABLE loan_due_installments ADD COLUMN restructure_installment_id UUID;
ALTER TABLE loan_due_installments ADD CONSTRAINT loan_due_installments_restructure_fk
  FOREIGN KEY (restructure_installment_id,organization_id)
  REFERENCES loan_restructure_installments(id,organization_id);
ALTER TABLE loan_due_installments ADD CONSTRAINT loan_due_installments_source_check CHECK (
  (contractual_installment_id IS NOT NULL)<>(restructure_installment_id IS NOT NULL)
);

CREATE INDEX idx_loan_restructures_contract ON loan_restructures(organization_id,contract_id,proposed_at);

CREATE OR REPLACE FUNCTION require_loan_restructure_engine()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_restructure_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Loan restructuring evidence is immutable outside the servicing engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;

CREATE TRIGGER loan_restructures_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_restructures
  FOR EACH ROW EXECUTE FUNCTION require_loan_restructure_engine();
CREATE TRIGGER loan_restructure_installments_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_restructure_installments
  FOR EACH ROW EXECUTE FUNCTION require_loan_restructure_engine();

CREATE OR REPLACE FUNCTION propose_loan_restructure(
  p_organization UUID,p_actor UUID,p_application UUID,p_contract UUID,
  p_effective_date DATE,p_first_due_date DATE,p_installment_count INTEGER,
  p_reason_code TEXT,p_reason TEXT,p_evidence JSONB,p_correlation UUID,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_contract loan_contracts; v_existing loan_restructures; v_restructure loan_restructures;
  v_outstanding BIGINT; v_hash TEXT; v_schedule JSONB:='[]'::JSONB; v_prior JSONB;
  v_base BIGINT; v_remainder BIGINT; v_sequence INTEGER; v_due DATE; v_amount BIGINT;
  v_schedule_snapshot JSONB; v_schedule_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
  IF p_effective_date IS NULL OR p_first_due_date IS NULL OR p_first_due_date<p_effective_date
    OR p_installment_count NOT BETWEEN 1 AND 600 OR p_reason_code!~'^[A-Z][A-Z0-9_]{2,39}$'
    OR length(btrim(p_reason)) NOT BETWEEN 12 AND 500 OR jsonb_typeof(p_evidence)<>'array'
    OR jsonb_array_length(p_evidence)=0 OR p_correlation IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'Loan restructuring proposal evidence is invalid'; END IF;

  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_application,p_contract,
    p_effective_date,p_first_due_date,p_installment_count,p_reason_code,btrim(p_reason),p_evidence::TEXT,
    p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-contract:'||p_contract::TEXT,0));
  SELECT * INTO v_existing FROM loan_restructures
    WHERE organization_id=p_organization AND proposal_idempotency_key=p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.contract_id<>p_contract OR v_existing.proposal_request_hash<>v_hash THEN
      RAISE EXCEPTION 'Idempotency key reused with different restructuring facts'; END IF;
    RETURN jsonb_build_object('restructure',to_jsonb(v_existing),'installments',
      (SELECT jsonb_agg(to_jsonb(item) ORDER BY sequence) FROM loan_restructure_installments item
       WHERE item.restructure_id=v_existing.id));
  END IF;

  SELECT * INTO v_contract FROM loan_contracts WHERE id=p_contract AND application_id=p_application
    AND organization_id=p_organization FOR UPDATE;
  IF v_contract.id IS NULL OR v_contract.state NOT IN ('active','delinquent','defaulted','restructured') THEN
    RAISE EXCEPTION 'Loan contract is not eligible for restructuring'; END IF;
  IF v_contract.interest_contractual_minor<>0 OR v_contract.fees_contractual_minor<>0 THEN
    RAISE EXCEPTION 'Interest-bearing or fee-bearing restructuring requires approved pricing recognition'; END IF;
  IF EXISTS(SELECT 1 FROM loan_restructures WHERE organization_id=p_organization AND contract_id=p_contract
    AND state='proposed') THEN RAISE EXCEPTION 'A restructuring proposal is already pending'; END IF;
  v_outstanding:=loan_contract_principal_outstanding(p_organization,p_contract);
  IF v_outstanding<=0 OR p_installment_count>v_outstanding THEN
    RAISE EXCEPTION 'Outstanding principal cannot support the proposed installment count'; END IF;
  v_base:=v_outstanding/p_installment_count; v_remainder:=v_outstanding-v_base*p_installment_count;
  FOR v_sequence IN 1..p_installment_count LOOP
    v_due:=p_first_due_date+(v_sequence-1)*30;
    v_amount:=v_base+CASE WHEN v_sequence=p_installment_count THEN v_remainder ELSE 0 END;
    v_schedule:=v_schedule||jsonb_build_array(jsonb_build_object('sequence',v_sequence,'dueOn',v_due,
      'principalDueMinor',v_amount,'interestDueMinor',0,'feeDueMinor',0,'totalDueMinor',v_amount));
  END LOOP;
  SELECT jsonb_build_object('contractId',p_contract,'capturedAt',p_at,'dueInstallments',
    COALESCE(jsonb_agg(to_jsonb(due_item) ORDER BY due_item.sequence),'[]'::JSONB)) INTO v_prior
  FROM loan_due_installments due_item WHERE organization_id=p_organization AND contract_id=p_contract;
  v_schedule_snapshot:=jsonb_build_object('version','CRD-09.RESTRUCTURE.1','effectiveDate',p_effective_date,
    'firstDueDate',p_first_due_date,'frequencyDays',30,'principalOutstandingMinor',v_outstanding,
    'installmentCount',p_installment_count,'installments',v_schedule);
  v_schedule_hash:=encode(digest(convert_to(v_schedule_snapshot::TEXT,'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_restructure_engine','on',TRUE);
  INSERT INTO loan_restructures(organization_id,application_id,contract_id,effective_date,first_due_date,
    installment_count,principal_outstanding_minor,reason_code,reason,evidence_references,
    prior_schedule_snapshot,proposed_schedule_snapshot,proposed_schedule_hash,proposed_by,proposed_at,
    proposal_idempotency_key,proposal_request_hash,proposal_correlation_id)
  VALUES(p_organization,p_application,p_contract,p_effective_date,p_first_due_date,p_installment_count,
    v_outstanding,p_reason_code,btrim(p_reason),p_evidence,v_prior,v_schedule_snapshot,v_schedule_hash,
    p_actor,p_at,p_idempotency_key,v_hash,p_correlation) RETURNING * INTO v_restructure;
  INSERT INTO loan_restructure_installments(organization_id,restructure_id,sequence,due_on,principal_due_minor)
  SELECT p_organization,v_restructure.id,(item->>'sequence')::INTEGER,(item->>'dueOn')::DATE,
    (item->>'principalDueMinor')::BIGINT FROM jsonb_array_elements(v_schedule) item;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_RESTRUCTURE_PROPOSED','loan_restructure',v_restructure.id::TEXT,
    jsonb_build_object('contract_id',p_contract,'schedule_hash',v_schedule_hash,
      'principal_outstanding_minor',v_outstanding),p_at);
  RETURN jsonb_build_object('restructure',to_jsonb(v_restructure),'installments',v_schedule);
END $$;

CREATE OR REPLACE FUNCTION decide_loan_restructure(
  p_organization UUID,p_actor UUID,p_restructure UUID,p_decision TEXT,p_review_reason TEXT,
  p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_restructure loan_restructures; v_existing loan_restructures; v_hash TEXT; v_max_sequence INTEGER;
  v_outstanding BIGINT; v_sum BIGINT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
  IF p_decision NOT IN ('approve','reject') OR length(btrim(p_review_reason)) NOT BETWEEN 12 AND 500
    OR p_correlation IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'Loan restructuring decision evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_restructure,p_decision,
    btrim(p_review_reason),p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
  SELECT * INTO v_existing FROM loan_restructures WHERE organization_id=p_organization
    AND review_idempotency_key=p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.id<>p_restructure OR v_existing.review_request_hash<>v_hash THEN
      RAISE EXCEPTION 'Idempotency key reused with different restructuring decision facts'; END IF;
    RETURN jsonb_build_object('restructure',to_jsonb(v_existing));
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-restructure:'||p_restructure::TEXT,0));
  SELECT * INTO v_restructure FROM loan_restructures WHERE id=p_restructure
    AND organization_id=p_organization FOR UPDATE;
  IF v_restructure.id IS NULL OR v_restructure.state<>'proposed' OR v_restructure.proposed_by=p_actor THEN
    RAISE EXCEPTION 'Restructuring proposal is not eligible for independent decision'; END IF;
  IF p_decision='approve' THEN
    v_outstanding:=loan_contract_principal_outstanding(p_organization,v_restructure.contract_id);
    SELECT SUM(principal_due_minor) INTO v_sum FROM loan_restructure_installments WHERE restructure_id=p_restructure;
    IF v_outstanding<>v_restructure.principal_outstanding_minor OR v_sum<>v_outstanding THEN
      RAISE EXCEPTION 'Outstanding principal changed after restructuring proposal'; END IF;
    SELECT COALESCE(MAX(sequence),0) INTO v_max_sequence FROM loan_due_installments
      WHERE organization_id=p_organization AND contract_id=v_restructure.contract_id AND state='paid';
    PERFORM set_config('microfams.loan_application_engine','on',TRUE);
    DELETE FROM loan_due_installments WHERE organization_id=p_organization
      AND contract_id=v_restructure.contract_id AND state IN ('due','partially_paid','overdue');
    INSERT INTO loan_due_installments(organization_id,contract_id,restructure_installment_id,sequence,kind,
      due_on,principal_due_minor,interest_due_minor,fee_due_minor,total_due_minor,state)
    SELECT p_organization,v_restructure.contract_id,item.id,v_max_sequence+item.sequence,'repayment',
      item.due_on,item.principal_due_minor,0,0,item.principal_due_minor,'due'
    FROM loan_restructure_installments item WHERE item.restructure_id=p_restructure ORDER BY item.sequence;
    UPDATE loan_contracts SET state='active' WHERE id=v_restructure.contract_id;
    UPDATE loan_applications SET state='restructured',updated_at=p_at WHERE id=v_restructure.application_id
      AND organization_id=p_organization;
  END IF;
  PERFORM set_config('microfams.loan_restructure_engine','on',TRUE);
  UPDATE loan_restructures SET state=CASE WHEN p_decision='approve' THEN 'approved' ELSE 'rejected' END,
    reviewed_by=p_actor,review_reason=btrim(p_review_reason),reviewed_at=p_at,
    review_idempotency_key=p_idempotency_key,review_request_hash=v_hash,review_correlation_id=p_correlation
    WHERE id=p_restructure RETURNING * INTO v_restructure;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,CASE WHEN p_decision='approve' THEN 'LOAN_RESTRUCTURE_APPROVED'
    ELSE 'LOAN_RESTRUCTURE_REJECTED' END,'loan_restructure',p_restructure::TEXT,
    jsonb_build_object('contract_id',v_restructure.contract_id,'schedule_hash',v_restructure.proposed_schedule_hash),p_at);
  RETURN jsonb_build_object('restructure',to_jsonb(v_restructure));
END $$;

REVOKE INSERT,UPDATE,DELETE ON loan_restructures,loan_restructure_installments FROM service_role;
GRANT SELECT ON loan_restructures,loan_restructure_installments TO service_role;
REVOKE ALL ON FUNCTION propose_loan_restructure(UUID,UUID,UUID,UUID,DATE,DATE,INTEGER,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_loan_restructure(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_loan_restructure(UUID,UUID,UUID,UUID,DATE,DATE,INTEGER,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decide_loan_restructure(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) TO service_role;
ALTER TABLE loan_restructures ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_restructure_installments ENABLE ROW LEVEL SECURITY;
