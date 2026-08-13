-- CRD-10: maker-checker principal write-off for defaulted zero-interest loans.
SET search_path = public, extensions;

CREATE TABLE loan_writeoffs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL,
  application_id UUID NOT NULL, contract_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','approved','rejected')),
  principal_outstanding_minor BIGINT NOT NULL CHECK (principal_outstanding_minor>0),
  reason_code TEXT NOT NULL CHECK (reason_code~'^[A-Z][A-Z0-9_]{2,39}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 12 AND 500),
  evidence_references JSONB NOT NULL CHECK (jsonb_typeof(evidence_references)='array' AND jsonb_array_length(evidence_references)>0),
  policy_snapshot JSONB NOT NULL CHECK (jsonb_typeof(policy_snapshot)='object'),
  proposed_by UUID NOT NULL REFERENCES users(id), proposed_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id), review_reason TEXT, reviewed_at TIMESTAMPTZ,
  loss_journal_entry_id UUID UNIQUE, proposal_idempotency_key TEXT NOT NULL,
  proposal_request_hash VARCHAR(64) NOT NULL CHECK (proposal_request_hash~'^[a-f0-9]{64}$'), proposal_correlation_id UUID NOT NULL,
  review_idempotency_key TEXT, review_request_hash VARCHAR(64), review_correlation_id UUID,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (contract_id,organization_id) REFERENCES loan_contracts(id,organization_id),
  FOREIGN KEY (loss_journal_entry_id) REFERENCES journal_entries(id),
  UNIQUE (organization_id,proposal_idempotency_key), UNIQUE (id,organization_id),
  CHECK ((state='proposed' AND reviewed_by IS NULL AND review_reason IS NULL AND reviewed_at IS NULL AND loss_journal_entry_id IS NULL)
    OR (state IN ('approved','rejected') AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by AND review_reason IS NOT NULL AND reviewed_at IS NOT NULL
      AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL AND review_correlation_id IS NOT NULL))
);
CREATE OR REPLACE FUNCTION require_loan_writeoff_engine() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.loan_writeoff_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Loan write-off evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER loan_writeoffs_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_writeoffs FOR EACH ROW EXECUTE FUNCTION require_loan_writeoff_engine();

CREATE OR REPLACE FUNCTION propose_loan_writeoff(p_organization UUID,p_actor UUID,p_application UUID,p_contract UUID,p_reason_code TEXT,p_reason TEXT,p_evidence JSONB,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c loan_contracts; a loan_applications; w loan_writeoffs; existing loan_writeoffs; out_principal BIGINT; h TEXT; policy JSONB; eligible_days INTEGER; latest_dpd INTEGER;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_application,p_contract,p_reason_code,btrim(p_reason),p_evidence::TEXT,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 SELECT * INTO existing FROM loan_writeoffs WHERE organization_id=p_organization AND proposal_idempotency_key=p_idempotency_key;
 IF existing.id IS NOT NULL THEN IF existing.proposal_request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different write-off facts'; END IF; RETURN jsonb_build_object('writeoff',to_jsonb(existing)); END IF;
 SELECT * INTO c FROM loan_contracts WHERE id=p_contract AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
 SELECT * INTO a FROM loan_applications WHERE id=p_application AND organization_id=p_organization;
 IF c.id IS NULL OR c.state NOT IN ('defaulted','delinquent') OR a.id IS NULL THEN RAISE EXCEPTION 'Loan contract is not eligible for write-off'; END IF;
 IF c.interest_contractual_minor<>0 OR c.fees_contractual_minor<>0 THEN RAISE EXCEPTION 'Interest-bearing or fee-bearing write-off requires approved loss recognition'; END IF;
 IF p_reason_code!~'^[A-Z][A-Z0-9_]{2,39}$' OR length(btrim(p_reason)) NOT BETWEEN 12 AND 500 OR jsonb_typeof(p_evidence)<>'array' OR jsonb_array_length(p_evidence)=0 OR p_correlation IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Loan write-off evidence is invalid'; END IF;
 out_principal:=loan_contract_principal_outstanding(p_organization,p_contract); IF out_principal<=0 THEN RAISE EXCEPTION 'No principal remains eligible for write-off'; END IF;
 policy:=COALESCE(a.product_rule_snapshot->'version'->'writeOffPolicy',a.product_rule_snapshot->'version'->'write_off_policy','{}'::JSONB);
 eligible_days:=COALESCE((policy->>'eligibleAfterDaysPastDue')::INTEGER,(policy->>'eligible_after_days_past_due')::INTEGER);
 SELECT MAX(days_past_due) INTO latest_dpd FROM loan_delinquency_assessments WHERE organization_id=p_organization AND contract_id=p_contract AND classification='defaulted';
 IF eligible_days IS NULL OR latest_dpd IS NULL OR latest_dpd<eligible_days THEN RAISE EXCEPTION 'Product write-off policy eligibility is not satisfied'; END IF;
 PERFORM set_config('microfams.loan_writeoff_engine','on',TRUE);
 INSERT INTO loan_writeoffs(organization_id,application_id,contract_id,principal_outstanding_minor,reason_code,reason,evidence_references,policy_snapshot,proposed_by,proposed_at,proposal_idempotency_key,proposal_request_hash,proposal_correlation_id)
 VALUES(p_organization,p_application,p_contract,out_principal,p_reason_code,btrim(p_reason),p_evidence,
   policy,
   p_actor,p_at,p_idempotency_key,h,p_correlation) RETURNING * INTO w;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'LOAN_WRITEOFF_PROPOSED','loan_writeoff',w.id::TEXT,jsonb_build_object('contract_id',p_contract,'principal_outstanding_minor',out_principal),p_at);
 RETURN jsonb_build_object('writeoff',to_jsonb(w));
END $$;

CREATE OR REPLACE FUNCTION decide_loan_writeoff(p_organization UUID,p_actor UUID,p_writeoff UUID,p_decision TEXT,p_review_reason TEXT,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE w loan_writeoffs; c loan_contracts; h TEXT; loss_account UUID; journal UUID; lines JSONB;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.service_existing') THEN RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_writeoff,p_decision,btrim(p_review_reason),p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 SELECT * INTO w FROM loan_writeoffs WHERE organization_id=p_organization AND review_idempotency_key=p_idempotency_key;
 IF w.id IS NOT NULL THEN IF w.id<>p_writeoff OR w.review_request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different write-off decision facts'; END IF; RETURN jsonb_build_object('writeoff',to_jsonb(w)); END IF;
 SELECT * INTO w FROM loan_writeoffs WHERE id=p_writeoff AND organization_id=p_organization FOR UPDATE;
 IF w.id IS NOT NULL AND w.proposed_by=p_actor THEN RAISE EXCEPTION 'Write-off requires independent approval'; END IF;
 IF w.id IS NULL OR w.state<>'proposed' OR p_decision NOT IN ('approve','reject') OR length(btrim(p_review_reason)) NOT BETWEEN 12 AND 500 THEN RAISE EXCEPTION 'Write-off decision is not eligible'; END IF;
 IF p_decision='approve' THEN
   SELECT * INTO c FROM loan_contracts WHERE id=w.contract_id AND organization_id=p_organization FOR UPDATE;
   IF loan_contract_principal_outstanding(p_organization,c.id)<>w.principal_outstanding_minor THEN RAISE EXCEPTION 'Outstanding principal changed after write-off proposal'; END IF;
   SELECT id INTO loss_account FROM financial_accounts WHERE organization_id=p_organization AND purpose='credit_loss_writeoff' AND owner_type='organization' AND owner_id IS NULL AND currency=c.currency AND effective_until IS NULL;
   IF loss_account IS NULL THEN loss_account:=(provision_financial_account(p_organization,p_actor,'LOAN.'||upper(substr(c.id::TEXT,1,12))||'.LOSS','Loan credit loss write-off','credit_loss_writeoff',c.currency,'organization',NULL,CURRENT_DATE,'loan-loss-'||c.id::TEXT)->>'id')::UUID; END IF;
   lines:=jsonb_build_array(jsonb_build_object('account_id',loss_account,'line_number',1,'side','debit','amount_minor',w.principal_outstanding_minor,'memo','Loan principal credit loss'),jsonb_build_object('account_id',c.principal_receivable_account_id,'line_number',2,'side','credit','amount_minor',w.principal_outstanding_minor,'memo','Write off loan principal receivable'));
   journal:=post_financial_journal(p_organization,c.currency,CURRENT_DATE,'loans.writeoff',c.id::TEXT,'loan-writeoff-'||w.id::TEXT,h,p_correlation,'Write off loan principal',p_actor,lines);
   PERFORM set_config('microfams.loan_application_engine','on',TRUE); UPDATE loan_contracts SET state='written_off' WHERE id=c.id; UPDATE loan_applications SET state='written_off',updated_at=p_at WHERE id=w.application_id;
 END IF;
 PERFORM set_config('microfams.loan_writeoff_engine','on',TRUE); UPDATE loan_writeoffs SET state=CASE WHEN p_decision='approve' THEN 'approved' ELSE 'rejected' END,reviewed_by=p_actor,review_reason=btrim(p_review_reason),reviewed_at=p_at,loss_journal_entry_id=journal,review_idempotency_key=p_idempotency_key,review_request_hash=h,review_correlation_id=p_correlation WHERE id=w.id RETURNING * INTO w;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,CASE WHEN p_decision='approve' THEN 'LOAN_WRITEOFF_APPROVED' ELSE 'LOAN_WRITEOFF_REJECTED' END,'loan_writeoff',w.id::TEXT,jsonb_build_object('contract_id',w.contract_id,'journal_entry_id',journal),p_at);
 RETURN jsonb_build_object('writeoff',to_jsonb(w));
END $$;
REVOKE INSERT,UPDATE,DELETE ON loan_writeoffs FROM service_role; GRANT SELECT ON loan_writeoffs TO service_role;
REVOKE ALL ON FUNCTION propose_loan_writeoff(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION propose_loan_writeoff(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) TO service_role;
REVOKE ALL ON FUNCTION decide_loan_writeoff(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION decide_loan_writeoff(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) TO service_role;
ALTER TABLE loan_writeoffs ENABLE ROW LEVEL SECURITY;
