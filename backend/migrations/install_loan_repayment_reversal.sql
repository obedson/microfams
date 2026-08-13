-- CRD-08: maker-checker reversal of settled zero-interest loan repayments.

SET search_path = public, extensions;

CREATE TABLE loan_repayment_reversals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  repayment_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','approved','rejected')),
  reason_code TEXT NOT NULL CHECK (reason_code~'^[A-Z][A-Z0-9_]{2,39}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 12 AND 500),
  evidence_references JSONB NOT NULL CHECK (
    jsonb_typeof(evidence_references)='array' AND jsonb_array_length(evidence_references)>0
  ),
  proposed_by UUID NOT NULL REFERENCES users(id),
  proposed_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id),
  review_reason TEXT,
  reviewed_at TIMESTAMPTZ,
  reversal_journal_entry_id UUID UNIQUE,
  proposal_idempotency_key TEXT NOT NULL CHECK (length(proposal_idempotency_key) BETWEEN 8 AND 160),
  proposal_request_hash VARCHAR(64) NOT NULL CHECK (proposal_request_hash~'^[a-f0-9]{64}$'),
  proposal_correlation_id UUID NOT NULL,
  review_idempotency_key TEXT CHECK (review_idempotency_key IS NULL OR length(review_idempotency_key) BETWEEN 8 AND 160),
  review_request_hash VARCHAR(64) CHECK (review_request_hash IS NULL OR review_request_hash~'^[a-f0-9]{64}$'),
  review_correlation_id UUID,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (contract_id,organization_id) REFERENCES loan_contracts(id,organization_id),
  FOREIGN KEY (repayment_id,organization_id) REFERENCES loan_repayments(id,organization_id),
  FOREIGN KEY (reversal_journal_entry_id) REFERENCES journal_entries(id),
  UNIQUE (organization_id,proposal_idempotency_key),
  UNIQUE (organization_id,repayment_id),
  UNIQUE (id,organization_id),
  CHECK ((state='proposed' AND reviewed_by IS NULL AND review_reason IS NULL
      AND reviewed_at IS NULL AND reversal_journal_entry_id IS NULL
      AND review_idempotency_key IS NULL AND review_request_hash IS NULL
      AND review_correlation_id IS NULL)
    OR (state='approved' AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by
      AND review_reason IS NOT NULL AND reviewed_at IS NOT NULL
      AND reversal_journal_entry_id IS NOT NULL AND review_idempotency_key IS NOT NULL
      AND review_request_hash IS NOT NULL AND review_correlation_id IS NOT NULL)
    OR (state='rejected' AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by
      AND review_reason IS NOT NULL AND reviewed_at IS NOT NULL
      AND reversal_journal_entry_id IS NULL AND review_idempotency_key IS NOT NULL
      AND review_request_hash IS NOT NULL AND review_correlation_id IS NOT NULL))
);

CREATE INDEX idx_loan_repayment_reversals_review
  ON loan_repayment_reversals(organization_id,state,proposed_at,id);

CREATE OR REPLACE FUNCTION require_loan_repayment_reversal_engine()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_repayment_reversal_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Loan repayment reversals are immutable outside the correction engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;

CREATE TRIGGER loan_repayment_reversals_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON loan_repayment_reversals
  FOR EACH ROW EXECUTE FUNCTION require_loan_repayment_reversal_engine();

CREATE OR REPLACE FUNCTION loan_contract_principal_outstanding(
  p_organization UUID,p_contract UUID
) RETURNS BIGINT LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT contract.principal_original_minor-COALESCE(SUM(repayment.principal_allocated_minor)
    FILTER (WHERE reversal.id IS NULL OR reversal.state<>'approved'),0)
  FROM loan_contracts contract
  LEFT JOIN loan_repayments repayment
    ON repayment.organization_id=contract.organization_id AND repayment.contract_id=contract.id
  LEFT JOIN loan_repayment_reversals reversal
    ON reversal.organization_id=repayment.organization_id AND reversal.repayment_id=repayment.id
  WHERE contract.organization_id=p_organization AND contract.id=p_contract
  GROUP BY contract.id,contract.principal_original_minor;
$$;

CREATE OR REPLACE FUNCTION loan_contract_interest_outstanding(
  p_organization UUID,p_contract UUID
) RETURNS BIGINT LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT contract.interest_contractual_minor-COALESCE(SUM(repayment.interest_allocated_minor)
    FILTER (WHERE reversal.id IS NULL OR reversal.state<>'approved'),0)
  FROM loan_contracts contract
  LEFT JOIN loan_repayments repayment
    ON repayment.organization_id=contract.organization_id AND repayment.contract_id=contract.id
  LEFT JOIN loan_repayment_reversals reversal
    ON reversal.organization_id=repayment.organization_id AND reversal.repayment_id=repayment.id
  WHERE contract.organization_id=p_organization AND contract.id=p_contract
  GROUP BY contract.id,contract.interest_contractual_minor;
$$;

CREATE OR REPLACE FUNCTION propose_loan_repayment_reversal(
  p_organization UUID,p_actor UUID,p_application UUID,p_contract UUID,p_repayment UUID,
  p_reason_code TEXT,p_reason TEXT,p_evidence JSONB,p_correlation UUID,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE v_repayment loan_repayments; v_existing loan_repayment_reversals;
  v_reversal loan_repayment_reversals; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
  IF p_reason_code IS NULL OR p_reason_code!~'^[A-Z][A-Z0-9_]{2,39}$'
    OR length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 500
    OR jsonb_typeof(p_evidence)<>'array' OR jsonb_array_length(p_evidence)=0
    OR p_correlation IS NULL OR p_idempotency_key IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_at IS NULL
  THEN RAISE EXCEPTION 'Loan repayment reversal proposal evidence is invalid'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,
    p_application::TEXT,p_contract::TEXT,p_repayment::TEXT,p_reason_code,btrim(p_reason),
    p_evidence::TEXT,p_correlation::TEXT,p_idempotency_key,p_at::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization::TEXT||':loan-repayment-reversal:'||p_repayment::TEXT,0));
  SELECT * INTO v_existing FROM loan_repayment_reversals
    WHERE organization_id=p_organization AND proposal_idempotency_key=p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.repayment_id<>p_repayment OR v_existing.proposal_request_hash<>v_hash
    THEN RAISE EXCEPTION 'Idempotency key reused with different reversal proposal facts'; END IF;
    RETURN jsonb_build_object('reversal',to_jsonb(v_existing));
  END IF;
  SELECT * INTO v_repayment FROM loan_repayments
    WHERE id=p_repayment AND organization_id=p_organization
      AND application_id=p_application AND contract_id=p_contract FOR UPDATE;
  IF v_repayment.id IS NULL THEN RAISE EXCEPTION 'Tenant loan repayment was not found'; END IF;
  IF v_repayment.interest_allocated_minor<>0 THEN
    RAISE EXCEPTION 'Interest-bearing repayment reversal requires linked recognition reversal'; END IF;
  IF EXISTS(SELECT 1 FROM loan_repayment_reversals
    WHERE organization_id=p_organization AND repayment_id=p_repayment)
  THEN RAISE EXCEPTION 'Loan repayment already has correction evidence'; END IF;
  PERFORM set_config('microfams.loan_repayment_reversal_engine','on',TRUE);
  INSERT INTO loan_repayment_reversals(organization_id,application_id,contract_id,
    repayment_id,reason_code,reason,evidence_references,proposed_by,proposed_at,
    proposal_idempotency_key,proposal_request_hash,proposal_correlation_id)
  VALUES(p_organization,p_application,p_contract,p_repayment,p_reason_code,btrim(p_reason),
    p_evidence,p_actor,p_at,p_idempotency_key,v_hash,p_correlation) RETURNING * INTO v_reversal;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,
    resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_REPAYMENT_REVERSAL_PROPOSED','loan_repayment_reversal',
    v_reversal.id::TEXT,jsonb_build_object('repayment_id',p_repayment,
      'reason_code',p_reason_code,'evidence_references',p_evidence),p_at);
  RETURN jsonb_build_object('reversal',to_jsonb(v_reversal));
END $$;

CREATE OR REPLACE FUNCTION decide_loan_repayment_reversal(
  p_organization UUID,p_actor UUID,p_reversal UUID,p_decision TEXT,p_review_reason TEXT,
  p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE v_reversal loan_repayment_reversals; v_repayment loan_repayments;
  v_hash TEXT; v_journal UUID; v_contract_state TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
  IF p_decision NOT IN ('approve','reject')
    OR length(btrim(COALESCE(p_review_reason,''))) NOT BETWEEN 12 AND 500
    OR p_correlation IS NULL OR p_idempotency_key IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_at IS NULL
  THEN RAISE EXCEPTION 'Loan repayment reversal decision evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization::TEXT||':loan-repayment-reversal:'||p_reversal::TEXT,0));
  SELECT * INTO v_reversal FROM loan_repayment_reversals
    WHERE id=p_reversal AND organization_id=p_organization FOR UPDATE;
  IF v_reversal.id IS NULL THEN RAISE EXCEPTION 'Loan repayment reversal was not found'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,
    p_reversal::TEXT,p_decision,btrim(p_review_reason),p_correlation::TEXT,
    p_idempotency_key,p_at::TEXT),'UTF8'),'sha256'),'hex');
  IF v_reversal.state<>'proposed' THEN
    IF v_reversal.review_idempotency_key=p_idempotency_key
      AND v_reversal.review_request_hash=v_hash
    THEN RETURN jsonb_build_object('reversal',to_jsonb(v_reversal)); END IF;
    RAISE EXCEPTION 'Loan repayment reversal is no longer reviewable';
  END IF;
  IF v_reversal.proposed_by=p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own correction'; END IF;

  IF p_decision='approve' THEN
    SELECT * INTO v_repayment FROM loan_repayments
      WHERE id=v_reversal.repayment_id AND organization_id=p_organization FOR UPDATE;
    IF v_repayment.interest_allocated_minor<>0 THEN
      RAISE EXCEPTION 'Interest-bearing repayment reversal requires linked recognition reversal'; END IF;
    v_journal:=reverse_financial_journal(v_repayment.journal_entry_id,
      'loan-repay-reversal-'||p_idempotency_key,p_correlation,p_actor,
      'Reverse settled loan repayment '||v_repayment.id::TEXT);
    v_contract_state:=CASE WHEN EXISTS(
      SELECT 1 FROM loan_delinquency_assessments assessment
      WHERE assessment.organization_id=p_organization
        AND assessment.contract_id=v_reversal.contract_id
        AND assessment.classification='defaulted'
        AND assessment.assessed_on=(SELECT MAX(latest.assessed_on)
          FROM loan_delinquency_assessments latest
          WHERE latest.organization_id=p_organization
            AND latest.contract_id=v_reversal.contract_id)
    ) THEN 'defaulted' WHEN EXISTS(
      SELECT 1 FROM loan_delinquency_assessments assessment
      WHERE assessment.organization_id=p_organization
        AND assessment.contract_id=v_reversal.contract_id
        AND assessment.classification='delinquent'
        AND assessment.assessed_on=(SELECT MAX(latest.assessed_on)
          FROM loan_delinquency_assessments latest
          WHERE latest.organization_id=p_organization
            AND latest.contract_id=v_reversal.contract_id)
    ) THEN 'delinquent' ELSE 'active' END;
    PERFORM set_config('microfams.loan_application_engine','on',TRUE);
    UPDATE loan_contracts SET state=v_contract_state WHERE id=v_reversal.contract_id;
    UPDATE loan_applications SET state=v_contract_state,updated_at=p_at
      WHERE id=v_reversal.application_id AND organization_id=p_organization;
  END IF;
  PERFORM set_config('microfams.loan_repayment_reversal_engine','on',TRUE);
  UPDATE loan_repayment_reversals SET state=CASE WHEN p_decision='approve' THEN 'approved' ELSE 'rejected' END,
    reviewed_by=p_actor,review_reason=btrim(p_review_reason),reviewed_at=p_at,
    reversal_journal_entry_id=v_journal,review_idempotency_key=p_idempotency_key,
    review_request_hash=v_hash,review_correlation_id=p_correlation WHERE id=p_reversal
  RETURNING * INTO v_reversal;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,
    resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,CASE WHEN p_decision='approve'
      THEN 'LOAN_REPAYMENT_REVERSAL_APPROVED' ELSE 'LOAN_REPAYMENT_REVERSAL_REJECTED' END,
    'loan_repayment_reversal',v_reversal.id::TEXT,jsonb_build_object(
      'repayment_id',v_reversal.repayment_id,'reversal_journal_entry_id',v_journal,
      'review_reason',btrim(p_review_reason)),p_at);
  RETURN jsonb_build_object('reversal',to_jsonb(v_reversal),'state',v_contract_state);
END $$;

REVOKE INSERT,UPDATE,DELETE ON loan_repayment_reversals FROM service_role;
GRANT SELECT ON loan_repayment_reversals TO service_role;
REVOKE ALL ON FUNCTION propose_loan_repayment_reversal(UUID,UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_loan_repayment_reversal(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_loan_repayment_reversal(UUID,UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decide_loan_repayment_reversal(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) TO service_role;
ALTER TABLE loan_repayment_reversals ENABLE ROW LEVEL SECURITY;
