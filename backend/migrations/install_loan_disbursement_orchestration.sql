-- CRD-05: versioned conditions precedent and provider-neutral loan
-- disbursement orchestration. Accounting and calendar due dates exist only
-- after confirmed provider success.

SET search_path = public, extensions;

INSERT INTO feature_flags(
  key,domain,description,default_enabled,failure_mode,risk
) VALUES (
  'financial.loans.disburse','loans',
  'Create new loan disbursement exposure through an approved provider route.',
  FALSE,'closed','regulated'
) ON CONFLICT (key) DO UPDATE SET
  domain=EXCLUDED.domain,description=EXCLUDED.description,
  default_enabled=EXCLUDED.default_enabled,failure_mode=EXCLUDED.failure_mode,
  risk=EXCLUDED.risk;

UPDATE organization_memberships SET permissions=(
  SELECT ARRAY(SELECT DISTINCT permission FROM unnest(
    COALESCE(permissions,'{}')||ARRAY['financial.loans.disburse']
  ) permission)
) WHERE role='owner';

CREATE OR REPLACE FUNCTION ensure_loan_disbursement_owner_permission()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.role='owner' AND NOT ('financial.loans.disburse'=ANY(COALESCE(NEW.permissions,'{}'))) THEN
    NEW.permissions:=array_append(COALESCE(NEW.permissions,'{}'),'financial.loans.disburse');
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION begin_loan_disbursement(
  p_organization UUID,p_actor UUID,p_application UUID,p_destination UUID,
  p_provider_name TEXT,p_provider_environment TEXT,p_idempotency_key TEXT,
  p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_app loan_applications; v_offer loan_offers; v_schedule loan_repayment_schedules;
  v_set RECORD; v_destination RECORD;
  v_disbursement RECORD; v_payout RECORD; v_event loan_application_events;
  v_attempt INTEGER; v_hash TEXT; v_previous_payout TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.disburse') THEN
    RAISE EXCEPTION 'Missing financial.loans.disburse permission'; END IF;
  IF p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic','sandbox','live')
    OR p_correlation_id IS NULL OR p_idempotency_key IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Loan disbursement request evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    SELECT * INTO v_disbursement FROM loan_disbursements
      WHERE id=(v_event.evidence->>'disbursement_id')::UUID AND organization_id=p_organization;
    SELECT * INTO v_payout FROM payouts WHERE id=v_disbursement.payout_id;
    IF v_event.application_id<>p_application OR v_disbursement.destination_id<>p_destination
      OR v_payout.id IS NULL THEN RAISE EXCEPTION 'Idempotency key reused with different disbursement facts'; END IF;
    RETURN jsonb_build_object('disbursement',to_jsonb(v_disbursement),'payout',to_jsonb(v_payout),
      'destination_ciphertext',(SELECT destination_ciphertext FROM loan_disbursement_destinations WHERE id=p_destination));
  END IF;
  SELECT * INTO v_app FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE application_id=p_application AND organization_id=p_organization AND state='accepted';
  SELECT * INTO v_schedule FROM loan_repayment_schedules
    WHERE application_id=p_application AND organization_id=p_organization;
  SELECT * INTO v_set FROM loan_condition_sets
    WHERE application_id=p_application AND organization_id=p_organization;
  SELECT * INTO v_destination FROM loan_disbursement_destinations
    WHERE id=p_destination AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_app.id IS NULL OR v_app.state<>'accepted' OR v_app.applicant_user_id=p_actor
    OR v_offer.id IS NULL OR v_schedule.id IS NULL OR v_set.id IS NULL OR v_set.state<>'ready'
    OR v_set.schedule_id<>v_schedule.id OR v_destination.id IS NULL OR v_destination.state<>'verified'
    OR v_destination.provider_name<>p_provider_name
    OR v_destination.provider_environment<>p_provider_environment THEN
    RAISE EXCEPTION 'Loan is not ready for independently controlled disbursement'; END IF;
  IF EXISTS(SELECT 1 FROM loan_disbursement_reconciliation_exceptions e
    JOIN loan_disbursements d ON d.id=e.disbursement_id
    WHERE d.organization_id=p_organization AND d.schedule_id=v_schedule.id AND e.state<>'resolved')
    OR EXISTS(SELECT 1 FROM loan_contracts WHERE organization_id=p_organization AND schedule_id=v_schedule.id) THEN
    RAISE EXCEPTION 'Loan disbursement is blocked by an active contract or reconciliation exception'; END IF;
  SELECT COALESCE(MAX(attempt),0)+1 INTO v_attempt FROM loan_disbursements
    WHERE organization_id=p_organization AND schedule_id=v_schedule.id;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_application::TEXT,
    v_offer.id::TEXT,v_schedule.id::TEXT,v_set.rules_hash,p_destination::TEXT,
    v_destination.destination_fingerprint,p_provider_name,p_provider_environment,
    v_offer.principal_minor::TEXT,v_offer.currency,p_actor::TEXT,v_attempt::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_disbursements(organization_id,application_id,offer_id,schedule_id,condition_set_id,
    destination_id,attempt,amount_minor,currency,provider_name,provider_environment,correlation_id,
    requested_by,requested_at)
  VALUES(p_organization,p_application,v_offer.id,v_schedule.id,v_set.id,p_destination,v_attempt,
    v_offer.principal_minor,v_offer.currency,p_provider_name,p_provider_environment,p_correlation_id,p_actor,p_at)
  RETURNING * INTO v_disbursement;
  v_previous_payout:=current_setting('microfams.payout_engine',TRUE);
  PERFORM set_config('microfams.payout_engine','on',TRUE);
  INSERT INTO payouts(organization_id,withdrawal_request_id,reservation_id,internal_reference,
    idempotency_key,request_hash,provider_name,provider_environment,currency,amount_minor,
    fee_amount_minor,beneficiary_fingerprint,beneficiary_masked,state,correlation_id,actor_id,
    source_type,source_id,loan_disbursement_id)
  VALUES(p_organization,NULL,NULL,'LDP-'||replace(v_disbursement.id::TEXT,'-',''),
    'loan-payout-'||replace(v_disbursement.id::TEXT,'-',''),v_hash,p_provider_name,p_provider_environment,
    v_offer.currency,v_offer.principal_minor,0,v_destination.destination_fingerprint,
    v_destination.destination_masked,'reserved',p_correlation_id,p_actor,
    'loan_disbursement',v_disbursement.id,v_disbursement.id)
  RETURNING * INTO v_payout;
  PERFORM set_config('microfams.payout_engine',COALESCE(v_previous_payout,''),TRUE);
  UPDATE loan_disbursements SET state='processing',payout_id=v_payout.id WHERE id=v_disbursement.id
    RETURNING * INTO v_disbursement;
  UPDATE loan_applications SET state='disbursement_pending',updated_at=p_at WHERE id=p_application;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,v_offer.id,v_schedule.id,'disbursement_started',p_actor,
    p_idempotency_key,v_hash,jsonb_build_object('disbursement_id',v_disbursement.id,'payout_id',v_payout.id,
      'attempt',v_attempt,'condition_set_id',v_set.id,'destination_id',p_destination,
      'provider_name',p_provider_name,'provider_environment',p_provider_environment),p_at);
  RETURN jsonb_build_object('disbursement',to_jsonb(v_disbursement),'payout',to_jsonb(v_payout),
    'destination_ciphertext',v_destination.destination_ciphertext);
END $$;

CREATE OR REPLACE FUNCTION ensure_loan_disbursement_account(
  p_organization UUID,p_actor UUID,p_owner_type TEXT,p_owner_id UUID,p_code TEXT,p_name TEXT,
  p_purpose TEXT,p_currency TEXT,p_key TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rule financial_account_purpose_rules; v_account financial_accounts; v_hash TEXT;
BEGIN
  SELECT * INTO v_rule FROM financial_account_purpose_rules WHERE purpose=p_purpose;
  IF v_rule.purpose IS NULL OR NOT p_owner_type=ANY(v_rule.allowed_owner_types) THEN
    RAISE EXCEPTION 'Loan account purpose is invalid'; END IF;
  SELECT * INTO v_account FROM financial_accounts
    WHERE organization_id=p_organization AND code=p_code AND currency=upper(p_currency);
  IF v_account.id IS NOT NULL THEN
    IF v_account.purpose<>p_purpose OR v_account.owner_type<>p_owner_type OR v_account.owner_id<>p_owner_id THEN
      RAISE EXCEPTION 'Loan account identity conflicts with an existing account'; END IF;
    RETURN v_account.id;
  END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_owner_type,p_owner_id::TEXT,
    p_code,p_purpose,upper(p_currency),p_key),'UTF8'),'sha256'),'hex');
  INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,
    owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
  VALUES(p_organization,p_code,p_name,v_rule.account_class,v_rule.normal_side,upper(p_currency),
    p_owner_type,p_owner_id,v_rule.is_control,p_actor,p_purpose,CURRENT_DATE,p_key,v_hash)
  RETURNING * INTO v_account;
  RETURN v_account.id;
END $$;

CREATE OR REPLACE FUNCTION succeed_loan_disbursement_payout(
  p_payout_id UUID,p_internal_reference TEXT,p_provider_reference TEXT,p_amount_minor BIGINT,
  p_currency TEXT,p_beneficiary_fingerprint TEXT,p_organization_id UUID,p_provider_name TEXT,
  p_provider_environment TEXT
) RETURNS payouts LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_payout RECORD; v_disbursement RECORD; v_app loan_applications;
  v_offer loan_offers; v_schedule loan_repayment_schedules; v_destination RECORD;
  v_contract RECORD; v_principal_account UUID; v_clearing_account UUID; v_journal UUID;
  v_lines JSONB; v_hash TEXT; v_snapshot JSONB; v_contract_hash TEXT;
  v_previous_payout TEXT; v_confirmed TIMESTAMPTZ:=NOW(); v_key TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id=p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL OR v_payout.source_type<>'loan_disbursement' THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_PAYOUT_NOT_FOUND'; END IF;
  IF p_internal_reference<>v_payout.internal_reference OR p_provider_reference IS NULL
    OR length(p_provider_reference) NOT BETWEEN 1 AND 160 OR p_amount_minor<>v_payout.amount_minor
    OR upper(p_currency)<>v_payout.currency
    OR lower(p_beneficiary_fingerprint)<>v_payout.beneficiary_fingerprint
    OR p_organization_id<>v_payout.organization_id OR p_provider_name<>v_payout.provider_name
    OR p_provider_environment<>v_payout.provider_environment
    OR (v_payout.provider_reference IS NOT NULL AND v_payout.provider_reference<>p_provider_reference) THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_PAYOUT_PROVIDER_MISMATCH'; END IF;
  IF v_payout.state='succeeded' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state,'succeeded') THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_PAYOUT_TRANSITION_INVALID'; END IF;
  SELECT * INTO v_disbursement FROM loan_disbursements
    WHERE id=v_payout.loan_disbursement_id AND organization_id=p_organization_id FOR UPDATE;
  SELECT * INTO v_app FROM loan_applications WHERE id=v_disbursement.application_id FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers WHERE id=v_disbursement.offer_id;
  SELECT * INTO v_schedule FROM loan_repayment_schedules WHERE id=v_disbursement.schedule_id;
  SELECT * INTO v_destination FROM loan_disbursement_destinations WHERE id=v_disbursement.destination_id;
  IF v_disbursement.id IS NULL OR v_disbursement.state<>'processing'
    OR v_app.state<>'disbursement_pending' OR v_offer.state<>'accepted'
    OR v_schedule.id IS NULL OR v_destination.state<>'verified' THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_NOT_PROCESSING'; END IF;
  IF EXISTS(SELECT 1 FROM loan_contracts WHERE organization_id=p_organization_id
    AND schedule_id=v_schedule.id) THEN RAISE EXCEPTION 'LOAN_CONTRACT_ALREADY_ACTIVE'; END IF;
  v_key:=upper(substr(md5(v_disbursement.id::TEXT),1,12));
  v_principal_account:=ensure_loan_disbursement_account(p_organization_id,v_disbursement.requested_by,
    'loan_contract',v_disbursement.id,'L.'||v_key||'.PRINCIPAL','Loan principal receivable',
    'loan_principal_receivable',v_payout.currency,'loan-principal-'||v_disbursement.id::TEXT);
  v_clearing_account:=ensure_loan_disbursement_account(p_organization_id,v_disbursement.requested_by,
    'provider',v_disbursement.id,'L.'||v_key||'.CLEARING','Loan provider clearing',
    'provider_clearing',v_payout.currency,'loan-clearing-'||v_disbursement.id::TEXT);
  v_hash:=encode(digest(convert_to(concat_ws('|',v_disbursement.id::TEXT,p_provider_reference,
    p_amount_minor::TEXT,upper(p_currency),p_beneficiary_fingerprint,v_confirmed::TEXT),'UTF8'),'sha256'),'hex');
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_principal_account,'line_number',1,'side','debit',
      'amount_minor',p_amount_minor,'memo','Confirmed loan principal receivable'),
    jsonb_build_object('account_id',v_clearing_account,'line_number',2,'side','credit',
      'amount_minor',p_amount_minor,'memo','Confirmed provider-funded disbursement')
  );
  v_journal:=post_financial_journal(p_organization_id,v_payout.currency,v_confirmed::DATE,
    'loans.disbursement',v_disbursement.id::TEXT,'loan-disb-'||v_disbursement.id::TEXT,
    v_hash,v_disbursement.correlation_id,'Activate confirmed loan receivable',
    v_disbursement.requested_by,v_lines);
  v_snapshot:=jsonb_build_object('contractVersion','CRD-05.CONTRACT.1','applicationId',v_app.id,
    'offerId',v_offer.id,'offerHash',v_offer.offer_hash,'scheduleId',v_schedule.id,
    'scheduleHash',v_schedule.schedule_hash,'disbursementId',v_disbursement.id,
    'providerName',v_payout.provider_name,'providerEnvironment',v_payout.provider_environment,
    'providerReference',p_provider_reference,'confirmedDisbursementAt',v_confirmed,
    'principalOriginalMinor',v_offer.principal_minor,'interestContractualMinor',v_offer.total_interest_minor,
    'feesContractualMinor',v_offer.total_fees_minor,'totalContractualMinor',v_offer.total_repayable_minor,
    'currency',v_offer.currency,'dueDateMaterialization','confirmed_date_plus_contractual_offset');
  v_contract_hash:=encode(digest(convert_to(v_snapshot::TEXT,'UTF8'),'sha256'),'hex');
  v_previous_payout:=current_setting('microfams.payout_engine',TRUE);
  PERFORM set_config('microfams.payout_engine','on',TRUE);
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE payouts SET state='succeeded',provider_reference=p_provider_reference,
    success_journal_entry_id=v_journal,terminal_at=v_confirmed,updated_at=v_confirmed
    WHERE id=v_payout.id RETURNING * INTO v_payout;
  UPDATE loan_disbursements SET state='succeeded',confirmed_at=v_confirmed,
    receivable_journal_entry_id=v_journal WHERE id=v_disbursement.id RETURNING * INTO v_disbursement;
  UPDATE loan_applications SET state='active',updated_at=v_confirmed WHERE id=v_app.id;
  INSERT INTO loan_contracts(organization_id,application_id,offer_id,schedule_id,disbursement_id,
    currency,principal_original_minor,interest_contractual_minor,fees_contractual_minor,
    total_contractual_minor,confirmed_disbursement_at,principal_receivable_account_id,
    provider_clearing_account_id,activation_journal_entry_id,activated_at,contract_snapshot,contract_hash)
  VALUES(p_organization_id,v_app.id,v_offer.id,v_schedule.id,v_disbursement.id,v_offer.currency,
    v_offer.principal_minor,v_offer.total_interest_minor,v_offer.total_fees_minor,v_offer.total_repayable_minor,
    v_confirmed,v_principal_account,v_clearing_account,v_journal,v_confirmed,v_snapshot,v_contract_hash)
  RETURNING * INTO v_contract;
  INSERT INTO loan_due_installments(organization_id,contract_id,contractual_installment_id,
    sequence,kind,due_on,principal_due_minor,interest_due_minor,fee_due_minor,total_due_minor)
  SELECT p_organization_id,v_contract.id,item.id,item.sequence,item.kind,
    v_confirmed::DATE+item.due_offset_days,item.principal_due_minor,item.interest_due_minor,
    item.fee_due_minor,item.total_due_minor
  FROM loan_repayment_installments item WHERE item.organization_id=p_organization_id
    AND item.schedule_id=v_schedule.id ORDER BY item.sequence;
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization_id,v_app.id,v_offer.id,v_schedule.id,'disbursement_succeeded',
    v_disbursement.requested_by,'loan-success-'||v_payout.id::TEXT,v_hash,
    jsonb_build_object('disbursement_id',v_disbursement.id,'payout_id',v_payout.id,
      'contract_id',v_contract.id,'journal_entry_id',v_journal,'contract_hash',v_contract_hash,
      'provider_reference',p_provider_reference),v_confirmed);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,
    after_value,occurred_at)
  VALUES(p_organization_id,v_disbursement.requested_by,'LOAN_DISBURSEMENT_CONFIRMED','loan_contract',
    v_contract.id::TEXT,jsonb_build_object('application_id',v_app.id,'disbursement_id',v_disbursement.id,
      'journal_entry_id',v_journal,'contract_hash',v_contract_hash),v_confirmed);
  PERFORM set_config('microfams.payout_engine',COALESCE(v_previous_payout,''),TRUE);
  RETURN v_payout;
END $$;

CREATE OR REPLACE FUNCTION fail_loan_disbursement_payout(
  p_payout_id UUID,p_failure_code TEXT,p_failure_reason TEXT
) RETURNS payouts LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_payout RECORD; v_disbursement RECORD; v_previous_payout TEXT; v_at TIMESTAMPTZ:=NOW();
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id=p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL OR v_payout.source_type<>'loan_disbursement' THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_PAYOUT_NOT_FOUND'; END IF;
  IF v_payout.state='failed' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state,'failed') THEN
    RAISE EXCEPTION 'LOAN_DISBURSEMENT_PAYOUT_TRANSITION_INVALID'; END IF;
  SELECT * INTO v_disbursement FROM loan_disbursements
    WHERE id=v_payout.loan_disbursement_id FOR UPDATE;
  v_previous_payout:=current_setting('microfams.payout_engine',TRUE);
  PERFORM set_config('microfams.payout_engine','on',TRUE);
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE payouts SET state='failed',failure_code=left(COALESCE(p_failure_code,'PROVIDER_FAILED'),80),
    failure_reason=left(COALESCE(p_failure_reason,'Provider reported disbursement failure'),500),
    terminal_at=v_at,updated_at=v_at WHERE id=p_payout_id RETURNING * INTO v_payout;
  UPDATE loan_disbursements SET state='failed',failed_at=v_at,
    failure_code=v_payout.failure_code,failure_reason=v_payout.failure_reason
    WHERE id=v_disbursement.id RETURNING * INTO v_disbursement;
  UPDATE loan_applications SET state='accepted',updated_at=v_at
    WHERE id=v_disbursement.application_id AND state='disbursement_pending';
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(v_payout.organization_id,v_disbursement.application_id,v_disbursement.offer_id,
    v_disbursement.schedule_id,'disbursement_failed',v_disbursement.requested_by,
    'loan-failure-'||v_payout.id::TEXT,encode(digest(convert_to(concat_ws('|',v_payout.id::TEXT,
      v_payout.failure_code,v_payout.failure_reason),'UTF8'),'sha256'),'hex'),
    jsonb_build_object('disbursement_id',v_disbursement.id,'payout_id',v_payout.id,
      'failure_code',v_payout.failure_code),v_at);
  PERFORM set_config('microfams.payout_engine',COALESCE(v_previous_payout,''),TRUE);
  RETURN v_payout;
END $$;

CREATE OR REPLACE FUNCTION record_loan_late_payout_success(
  p_payout_id UUID,p_organization_id UUID,p_provider_reference TEXT,p_amount_minor BIGINT,
  p_currency TEXT,p_beneficiary_fingerprint TEXT,p_provider_name TEXT,p_provider_environment TEXT,
  p_evidence_snapshot JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_payout RECORD; v_disbursement RECORD;
  v_exception RECORD; v_at TIMESTAMPTZ:=NOW();
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id=p_payout_id AND organization_id=p_organization_id FOR UPDATE;
  IF v_payout.id IS NULL OR v_payout.source_type<>'loan_disbursement' OR v_payout.state NOT IN ('failed','cancelled')
    OR p_provider_reference IS NULL OR p_amount_minor<>v_payout.amount_minor
    OR upper(p_currency)<>v_payout.currency OR lower(p_beneficiary_fingerprint)<>v_payout.beneficiary_fingerprint
    OR p_provider_name<>v_payout.provider_name OR p_provider_environment<>v_payout.provider_environment
    OR jsonb_typeof(p_evidence_snapshot)<>'object' THEN
    RAISE EXCEPTION 'LOAN_LATE_PAYOUT_EVIDENCE_MISMATCH'; END IF;
  SELECT * INTO v_exception FROM loan_disbursement_reconciliation_exceptions
    WHERE organization_id=p_organization_id AND payout_id=p_payout_id;
  IF v_exception.id IS NOT NULL THEN RETURN to_jsonb(v_exception); END IF;
  SELECT * INTO v_disbursement FROM loan_disbursements WHERE id=v_payout.loan_disbursement_id FOR UPDATE;
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_disbursement_reconciliation_exceptions(organization_id,disbursement_id,payout_id,
    exception_type,provider_reference,amount_minor,currency,evidence_snapshot,detected_at)
  VALUES(p_organization_id,v_disbursement.id,p_payout_id,'late_provider_success',p_provider_reference,
    p_amount_minor,upper(p_currency),p_evidence_snapshot,v_at) RETURNING * INTO v_exception;
  UPDATE loan_disbursements SET state='reconciliation_required' WHERE id=v_disbursement.id;
  UPDATE loan_applications SET state='disbursement_pending',updated_at=v_at
    WHERE id=v_disbursement.application_id AND state='accepted';
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization_id,v_disbursement.application_id,v_disbursement.offer_id,v_disbursement.schedule_id,
    'disbursement_reconciliation_required',v_disbursement.requested_by,
    'loan-late-'||p_payout_id::TEXT,encode(digest(convert_to(concat_ws('|',p_payout_id::TEXT,
      p_provider_reference,p_amount_minor::TEXT,p_currency),'UTF8'),'sha256'),'hex'),
    jsonb_build_object('disbursement_id',v_disbursement.id,'payout_id',p_payout_id,
      'exception_id',v_exception.id,'provider_reference',p_provider_reference),v_at);
  RETURN to_jsonb(v_exception);
END $$;
DROP TRIGGER IF EXISTS organization_owner_loan_disbursement_permission ON organization_memberships;
CREATE TRIGGER organization_owner_loan_disbursement_permission
  BEFORE INSERT OR UPDATE OF role,permissions ON organization_memberships
  FOR EACH ROW EXECUTE FUNCTION ensure_loan_disbursement_owner_permission();

ALTER TABLE loan_applications DROP CONSTRAINT loan_applications_state_check;
ALTER TABLE loan_applications ADD CONSTRAINT loan_applications_state_check CHECK (state IN (
  'draft','submitted','identity_review','affordability_review','credit_review',
  'offered','accepted','disbursement_pending','active','paid_off','declined',
  'withdrawn','cancelled','delinquent','defaulted','restructured','written_off'
));

ALTER TABLE loan_application_events DROP CONSTRAINT loan_application_events_action_check;
ALTER TABLE loan_application_events ADD CONSTRAINT loan_application_events_action_check CHECK (action IN (
  'application_created','application_submitted','adverse_review_requested',
  'adverse_review_upheld','adverse_review_reopened','application_withdrawn',
  'credit_review_declined','offer_issued','offer_revised','offer_accepted','offer_expired',
  'repayment_schedule_generated','conditions_initialized','condition_evidence_submitted',
  'condition_satisfied','condition_rejected','disbursement_destination_proposed',
  'disbursement_destination_verified','disbursement_destination_rejected',
  'disbursement_started','disbursement_succeeded','disbursement_failed',
  'disbursement_reconciliation_required'
));

CREATE TABLE loan_condition_sets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  offer_id UUID NOT NULL,
  schedule_id UUID NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version>0),
  rules_version TEXT NOT NULL CHECK (length(btrim(rules_version)) BETWEEN 1 AND 80),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','ready')),
  offer_hash VARCHAR(64) NOT NULL CHECK (offer_hash~'^[a-f0-9]{64}$'),
  schedule_hash VARCHAR(64) NOT NULL CHECK (schedule_hash~'^[a-f0-9]{64}$'),
  rules_snapshot JSONB NOT NULL CHECK (jsonb_typeof(rules_snapshot)='object'),
  rules_hash VARCHAR(64) NOT NULL CHECK (rules_hash~'^[a-f0-9]{64}$'),
  initialized_by UUID NOT NULL REFERENCES users(id),
  initialized_at TIMESTAMPTZ NOT NULL,
  ready_at TIMESTAMPTZ,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (offer_id,application_id,organization_id)
    REFERENCES loan_offers(id,application_id,organization_id),
  FOREIGN KEY (schedule_id,application_id,organization_id)
    REFERENCES loan_repayment_schedules(id,application_id,organization_id),
  UNIQUE (organization_id,schedule_id),
  UNIQUE (organization_id,application_id,version),
  UNIQUE (id,organization_id),
  CHECK ((state='ready' AND ready_at IS NOT NULL) OR (state='pending' AND ready_at IS NULL))
);

CREATE TABLE loan_conditions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  condition_set_id UUID NOT NULL,
  application_id UUID NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 100),
  code TEXT NOT NULL CHECK (code~'^[A-Z][A-Z0-9_]{2,79}$'),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','submitted','satisfied','rejected')),
  current_evidence_id UUID,
  satisfied_at TIMESTAMPTZ,
  FOREIGN KEY (condition_set_id,organization_id) REFERENCES loan_condition_sets(id,organization_id),
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  UNIQUE (organization_id,condition_set_id,sequence),
  UNIQUE (organization_id,condition_set_id,code),
  UNIQUE (id,organization_id),
  CHECK ((state='satisfied' AND satisfied_at IS NOT NULL) OR (state<>'satisfied' AND satisfied_at IS NULL))
);

CREATE TABLE loan_condition_evidence (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  condition_id UUID NOT NULL,
  attempt INTEGER NOT NULL CHECK (attempt>0),
  state TEXT NOT NULL DEFAULT 'submitted' CHECK (state IN ('submitted','satisfied','rejected')),
  evidence_references JSONB NOT NULL CHECK (valid_loan_reference_array(evidence_references)),
  evidence_hash VARCHAR(64) NOT NULL CHECK (evidence_hash~'^[a-f0-9]{64}$'),
  submitted_by UUID NOT NULL REFERENCES users(id),
  submitted_at TIMESTAMPTZ NOT NULL,
  decided_by UUID REFERENCES users(id),
  decision_reason TEXT,
  decided_at TIMESTAMPTZ,
  FOREIGN KEY (condition_id,organization_id) REFERENCES loan_conditions(id,organization_id),
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  UNIQUE (organization_id,condition_id,attempt),
  UNIQUE (id,organization_id),
  CHECK ((state='submitted' AND decided_by IS NULL AND decision_reason IS NULL AND decided_at IS NULL)
    OR (state IN ('satisfied','rejected') AND decided_by IS NOT NULL
      AND length(btrim(decision_reason)) BETWEEN 12 AND 1000 AND decided_at IS NOT NULL)),
  CHECK (decided_by IS NULL OR decided_by<>submitted_by)
);
ALTER TABLE loan_conditions ADD CONSTRAINT loan_conditions_current_evidence_fk
  FOREIGN KEY (current_evidence_id,organization_id)
  REFERENCES loan_condition_evidence(id,organization_id);

CREATE TABLE loan_disbursement_destinations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  provider_name TEXT NOT NULL CHECK (provider_name~'^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic','sandbox','live')),
  destination_ciphertext TEXT NOT NULL CHECK (length(destination_ciphertext) BETWEEN 32 AND 4096),
  destination_fingerprint VARCHAR(64) NOT NULL CHECK (destination_fingerprint~'^[a-f0-9]{64}$'),
  destination_masked TEXT NOT NULL CHECK (length(destination_masked) BETWEEN 4 AND 40),
  account_name_masked TEXT NOT NULL CHECK (length(btrim(account_name_masked)) BETWEEN 2 AND 160),
  verification_snapshot JSONB NOT NULL CHECK (jsonb_typeof(verification_snapshot)='object'),
  verification_version TEXT NOT NULL CHECK (length(btrim(verification_version)) BETWEEN 1 AND 80),
  state TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','verified','rejected','retired')),
  proposed_by UUID NOT NULL REFERENCES users(id),
  proposed_at TIMESTAMPTZ NOT NULL,
  decided_by UUID REFERENCES users(id),
  decision_reason TEXT,
  decided_at TIMESTAMPTZ,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  UNIQUE (id,application_id,organization_id),
  CHECK ((state='proposed' AND decided_by IS NULL AND decision_reason IS NULL AND decided_at IS NULL)
    OR (state IN ('verified','rejected') AND decided_by IS NOT NULL
      AND length(btrim(decision_reason)) BETWEEN 12 AND 1000 AND decided_at IS NOT NULL)
    OR state='retired'),
  CHECK (decided_by IS NULL OR decided_by<>proposed_by)
);
CREATE UNIQUE INDEX uq_verified_loan_disbursement_destination
  ON loan_disbursement_destinations(organization_id,application_id)
  WHERE state='verified';

CREATE TABLE loan_disbursements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  offer_id UUID NOT NULL,
  schedule_id UUID NOT NULL,
  condition_set_id UUID NOT NULL,
  destination_id UUID NOT NULL,
  attempt INTEGER NOT NULL CHECK (attempt>0),
  state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN (
    'ready','processing','succeeded','failed','reconciliation_required'
  )),
  amount_minor BIGINT NOT NULL CHECK (amount_minor>0),
  currency VARCHAR(3) NOT NULL CHECK (currency~'^[A-Z]{3}$'),
  provider_name TEXT NOT NULL CHECK (provider_name~'^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic','sandbox','live')),
  payout_id UUID,
  correlation_id UUID NOT NULL,
  requested_by UUID NOT NULL REFERENCES users(id),
  requested_at TIMESTAMPTZ NOT NULL,
  confirmed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  receivable_journal_entry_id UUID UNIQUE,
  failure_code TEXT,
  failure_reason TEXT,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (offer_id,application_id,organization_id)
    REFERENCES loan_offers(id,application_id,organization_id),
  FOREIGN KEY (schedule_id,application_id,organization_id)
    REFERENCES loan_repayment_schedules(id,application_id,organization_id),
  FOREIGN KEY (condition_set_id,organization_id) REFERENCES loan_condition_sets(id,organization_id),
  FOREIGN KEY (destination_id,application_id,organization_id)
    REFERENCES loan_disbursement_destinations(id,application_id,organization_id),
  FOREIGN KEY (receivable_journal_entry_id,organization_id,currency)
    REFERENCES journal_entries(id,organization_id,currency),
  UNIQUE (organization_id,schedule_id,attempt),
  UNIQUE (id,organization_id),
  CHECK ((state='succeeded' AND payout_id IS NOT NULL AND confirmed_at IS NOT NULL
      AND receivable_journal_entry_id IS NOT NULL)
    OR (state='failed' AND payout_id IS NOT NULL AND failed_at IS NOT NULL)
    OR state IN ('ready','processing','reconciliation_required'))
);
CREATE UNIQUE INDEX uq_successful_loan_disbursement
  ON loan_disbursements(organization_id,schedule_id) WHERE state='succeeded';
CREATE UNIQUE INDEX uq_inflight_loan_disbursement
  ON loan_disbursements(organization_id,schedule_id) WHERE state IN ('ready','processing');

CREATE TABLE loan_contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  offer_id UUID NOT NULL,
  schedule_id UUID NOT NULL,
  disbursement_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','paid_off','delinquent','defaulted','restructured','written_off')),
  currency VARCHAR(3) NOT NULL CHECK (currency~'^[A-Z]{3}$'),
  principal_original_minor BIGINT NOT NULL CHECK (principal_original_minor>0),
  interest_contractual_minor BIGINT NOT NULL CHECK (interest_contractual_minor>=0),
  fees_contractual_minor BIGINT NOT NULL CHECK (fees_contractual_minor>=0),
  total_contractual_minor BIGINT NOT NULL,
  confirmed_disbursement_at TIMESTAMPTZ NOT NULL,
  principal_receivable_account_id UUID NOT NULL,
  provider_clearing_account_id UUID NOT NULL,
  activation_journal_entry_id UUID NOT NULL UNIQUE,
  activated_at TIMESTAMPTZ NOT NULL,
  contract_snapshot JSONB NOT NULL CHECK (jsonb_typeof(contract_snapshot)='object'),
  contract_hash VARCHAR(64) NOT NULL CHECK (contract_hash~'^[a-f0-9]{64}$'),
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (offer_id,application_id,organization_id)
    REFERENCES loan_offers(id,application_id,organization_id),
  FOREIGN KEY (schedule_id,application_id,organization_id)
    REFERENCES loan_repayment_schedules(id,application_id,organization_id),
  FOREIGN KEY (disbursement_id,organization_id) REFERENCES loan_disbursements(id,organization_id),
  FOREIGN KEY (principal_receivable_account_id,organization_id,currency)
    REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY (provider_clearing_account_id,organization_id,currency)
    REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY (activation_journal_entry_id,organization_id,currency)
    REFERENCES journal_entries(id,organization_id,currency),
  UNIQUE (organization_id,schedule_id),
  UNIQUE (organization_id,application_id),
  UNIQUE (id,organization_id),
  CHECK (total_contractual_minor=principal_original_minor+interest_contractual_minor+fees_contractual_minor)
);

CREATE TABLE loan_due_installments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  contractual_installment_id UUID NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence BETWEEN 0 AND 600),
  kind TEXT NOT NULL CHECK (kind IN ('upfront','repayment')),
  due_on DATE NOT NULL,
  principal_due_minor BIGINT NOT NULL CHECK (principal_due_minor>=0),
  interest_due_minor BIGINT NOT NULL CHECK (interest_due_minor>=0),
  fee_due_minor BIGINT NOT NULL CHECK (fee_due_minor>=0),
  total_due_minor BIGINT NOT NULL CHECK (total_due_minor>0),
  state TEXT NOT NULL DEFAULT 'due' CHECK (state IN ('due','partially_paid','paid','overdue','waived')),
  FOREIGN KEY (contract_id,organization_id) REFERENCES loan_contracts(id,organization_id),
  FOREIGN KEY (contractual_installment_id,organization_id)
    REFERENCES loan_repayment_installments(id,organization_id),
  UNIQUE (organization_id,contract_id,sequence),
  UNIQUE (organization_id,contractual_installment_id),
  UNIQUE (id,organization_id),
  CHECK (total_due_minor=principal_due_minor+interest_due_minor+fee_due_minor)
);

CREATE TABLE loan_disbursement_reconciliation_exceptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  disbursement_id UUID NOT NULL,
  payout_id UUID NOT NULL,
  exception_type TEXT NOT NULL CHECK (exception_type='late_provider_success'),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','investigating','resolved')),
  provider_reference TEXT NOT NULL CHECK (length(provider_reference) BETWEEN 1 AND 160),
  amount_minor BIGINT NOT NULL CHECK (amount_minor>0),
  currency VARCHAR(3) NOT NULL CHECK (currency~'^[A-Z]{3}$'),
  evidence_snapshot JSONB NOT NULL CHECK (jsonb_typeof(evidence_snapshot)='object'),
  detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (disbursement_id,organization_id) REFERENCES loan_disbursements(id,organization_id),
  UNIQUE (organization_id,payout_id),
  UNIQUE (id,organization_id)
);

-- Older legacy databases can have the provider-neutral group payout functions
-- without the source column introduced by the final GT-09 migration revision.
-- Repair that additive column before replacing the exhaustive source-shape check.
ALTER TABLE payouts
  ADD COLUMN IF NOT EXISTS group_treasury_disbursement_id UUID
    REFERENCES group_treasury_disbursements(id);
ALTER TABLE payouts ADD COLUMN IF NOT EXISTS loan_disbursement_id UUID;
ALTER TABLE payouts ADD CONSTRAINT payouts_loan_disbursement_fk
  FOREIGN KEY (loan_disbursement_id,organization_id)
  REFERENCES loan_disbursements(id,organization_id);
ALTER TABLE loan_disbursements ADD CONSTRAINT loan_disbursements_payout_fk
  FOREIGN KEY (payout_id) REFERENCES payouts(id);

ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_source_type_check;
ALTER TABLE payouts ADD CONSTRAINT payouts_source_type_check CHECK (
  source_type IN ('wallet_withdrawal','booking_settlement','group_treasury','loan_disbursement')
);
ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_source_shape;
ALTER TABLE payouts ADD CONSTRAINT payouts_source_shape CHECK (
  (source_type='wallet_withdrawal' AND withdrawal_request_id IS NOT NULL
    AND reservation_id IS NOT NULL AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL AND group_treasury_disbursement_id IS NULL
    AND loan_disbursement_id IS NULL AND source_id=withdrawal_request_id)
  OR (source_type='booking_settlement' AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL AND booking_settlement_release_id IS NOT NULL
    AND booking_payout_beneficiary_id IS NOT NULL AND group_treasury_disbursement_id IS NULL
    AND loan_disbursement_id IS NULL AND source_id=booking_settlement_release_id)
  OR (source_type='group_treasury' AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL AND group_treasury_disbursement_id IS NOT NULL
    AND loan_disbursement_id IS NULL AND source_id=group_treasury_disbursement_id)
  OR (source_type='loan_disbursement' AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL AND group_treasury_disbursement_id IS NULL
    AND loan_disbursement_id IS NOT NULL AND source_id=loan_disbursement_id)
);

CREATE INDEX idx_loan_conditions_queue
  ON loan_conditions(organization_id,application_id,state);
CREATE INDEX idx_loan_disbursement_queue
  ON loan_disbursements(organization_id,state,requested_at);
CREATE INDEX idx_loan_due_installments
  ON loan_due_installments(organization_id,contract_id,due_on,sequence);

CREATE TRIGGER loan_condition_sets_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_condition_sets
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_conditions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_conditions
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_condition_evidence_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_condition_evidence
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_disbursement_destinations_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_disbursement_destinations
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_disbursements_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_disbursements
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_contracts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_contracts
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_due_installments_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_due_installments
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_disbursement_reconciliation_engine_only BEFORE INSERT OR UPDATE OR DELETE
  ON loan_disbursement_reconciliation_exceptions
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();

CREATE OR REPLACE FUNCTION loan_actor_can_supply_condition(
  p_application loan_applications,p_actor UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT p_application.applicant_user_id=p_actor
    OR has_financial_permission(p_application.organization_id,p_actor,'financial.loans.disburse');
$$;

CREATE OR REPLACE FUNCTION initialize_loan_conditions(
  p_organization UUID,p_actor UUID,p_application UUID,p_offer UUID,p_schedule UUID,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_app loan_applications; v_offer loan_offers; v_schedule loan_repayment_schedules;
  v_set loan_condition_sets; v_event loan_application_events; v_snapshot JSONB; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.disburse') THEN
    RAISE EXCEPTION 'Missing financial.loans.disburse permission'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Condition initialization idempotency evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    SELECT * INTO v_set FROM loan_condition_sets
      WHERE id=(v_event.evidence->>'condition_set_id')::UUID AND organization_id=p_organization;
    IF v_event.application_id<>p_application OR v_set.id IS NULL THEN
      RAISE EXCEPTION 'Idempotency key reused with different condition facts'; END IF;
    RETURN jsonb_build_object('condition_set',to_jsonb(v_set),'conditions',(
      SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sequence),'[]'::JSONB)
      FROM loan_conditions c WHERE c.condition_set_id=v_set.id));
  END IF;
  SELECT * INTO v_app FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE id=p_offer AND application_id=p_application AND organization_id=p_organization;
  SELECT * INTO v_schedule FROM loan_repayment_schedules
    WHERE id=p_schedule AND application_id=p_application AND organization_id=p_organization;
  IF v_app.id IS NULL OR v_app.state<>'accepted' OR v_app.applicant_user_id=p_actor
    OR v_offer.id IS NULL OR v_offer.state<>'accepted' OR v_schedule.id IS NULL
    OR v_schedule.offer_id<>v_offer.id THEN
    RAISE EXCEPTION 'Accepted scheduled offer is not eligible for independent condition initialization';
  END IF;
  IF EXISTS(SELECT 1 FROM loan_condition_sets WHERE organization_id=p_organization AND schedule_id=p_schedule) THEN
    RAISE EXCEPTION 'Condition set already exists for this schedule'; END IF;
  v_snapshot:=jsonb_build_object('rulesVersion','CRD-05.CONDITIONS.1','offerId',v_offer.id,
    'offerHash',v_offer.offer_hash,'scheduleId',v_schedule.id,'scheduleHash',v_schedule.schedule_hash,
    'conditionCodes',to_jsonb(v_offer.condition_codes),'makerCheckerRequired',TRUE,
    'destinationVerificationRequired',TRUE,'providerConfirmationRequired',TRUE);
  v_hash:=encode(digest(convert_to(v_snapshot::TEXT,'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_condition_sets(organization_id,application_id,offer_id,schedule_id,rules_version,
    state,offer_hash,schedule_hash,rules_snapshot,rules_hash,initialized_by,initialized_at,ready_at)
  VALUES(p_organization,p_application,p_offer,p_schedule,'CRD-05.CONDITIONS.1',
    CASE WHEN cardinality(v_offer.condition_codes)=0 THEN 'ready' ELSE 'pending' END,
    v_offer.offer_hash,v_schedule.schedule_hash,v_snapshot,v_hash,p_actor,p_at,
    CASE WHEN cardinality(v_offer.condition_codes)=0 THEN p_at ELSE NULL END)
  RETURNING * INTO v_set;
  INSERT INTO loan_conditions(organization_id,condition_set_id,application_id,sequence,code)
  SELECT p_organization,v_set.id,p_application,position,code
  FROM unnest(v_offer.condition_codes) WITH ORDINALITY AS condition(code,position);
  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,p_offer,p_schedule,'conditions_initialized',p_actor,
    p_idempotency_key,encode(digest(convert_to(concat_ws('|',p_actor::TEXT,v_hash),'UTF8'),'sha256'),'hex'),
    jsonb_build_object('condition_set_id',v_set.id,'rules_hash',v_hash,
      'condition_count',cardinality(v_offer.condition_codes)),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_CONDITIONS_INITIALIZED','loan_condition_set',v_set.id::TEXT,
    jsonb_build_object('application_id',p_application,'rules_hash',v_hash),p_at);
  RETURN jsonb_build_object('condition_set',to_jsonb(v_set),'conditions',(
    SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sequence),'[]'::JSONB)
    FROM loan_conditions c WHERE c.condition_set_id=v_set.id));
END $$;

CREATE OR REPLACE FUNCTION submit_loan_condition_evidence(
  p_organization UUID,p_actor UUID,p_application UUID,p_condition UUID,p_evidence JSONB,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_app loan_applications; v_condition loan_conditions; v_item loan_condition_evidence;
  v_event loan_application_events; v_attempt INTEGER; v_hash TEXT;
BEGIN
  IF NOT valid_loan_reference_array(p_evidence) OR jsonb_array_length(p_evidence)=0 THEN
    RAISE EXCEPTION 'Condition evidence references are invalid'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Condition evidence idempotency key is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-condition:'||p_condition::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    SELECT * INTO v_item FROM loan_condition_evidence
      WHERE id=(v_event.evidence->>'evidence_id')::UUID AND organization_id=p_organization;
    IF v_event.application_id<>p_application OR v_item.condition_id<>p_condition THEN
      RAISE EXCEPTION 'Idempotency key reused with different condition evidence'; END IF;
    RETURN jsonb_build_object('condition_evidence',to_jsonb(v_item));
  END IF;
  SELECT * INTO v_app FROM loan_applications WHERE id=p_application AND organization_id=p_organization;
  SELECT * INTO v_condition FROM loan_conditions
    WHERE id=p_condition AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_app.id IS NULL OR v_condition.id IS NULL OR v_app.state<>'accepted'
    OR NOT loan_actor_can_supply_condition(v_app,p_actor) THEN
    RAISE EXCEPTION 'Actor cannot supply this loan condition'; END IF;
  IF v_condition.state IN ('submitted','satisfied') THEN
    RAISE EXCEPTION 'Loan condition is not awaiting new evidence'; END IF;
  SELECT COALESCE(MAX(attempt),0)+1 INTO v_attempt FROM loan_condition_evidence
    WHERE organization_id=p_organization AND condition_id=p_condition;
  v_hash:=encode(digest(convert_to(jsonb_build_object('conditionId',p_condition,'attempt',v_attempt,
    'evidenceReferences',p_evidence,'submittedBy',p_actor)::TEXT,'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_condition_evidence(organization_id,application_id,condition_id,attempt,
    evidence_references,evidence_hash,submitted_by,submitted_at)
  VALUES(p_organization,p_application,p_condition,v_attempt,p_evidence,v_hash,p_actor,p_at)
  RETURNING * INTO v_item;
  UPDATE loan_conditions SET state='submitted',current_evidence_id=v_item.id,satisfied_at=NULL
    WHERE id=p_condition;
  UPDATE loan_condition_sets SET state='pending',ready_at=NULL WHERE id=v_condition.condition_set_id;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,
    request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,'condition_evidence_submitted',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('condition_id',p_condition,'evidence_id',v_item.id,
      'evidence_hash',v_hash,'attempt',v_attempt),p_at);
  RETURN jsonb_build_object('condition_evidence',to_jsonb(v_item));
END $$;

CREATE OR REPLACE FUNCTION decide_loan_condition(
  p_organization UUID,p_actor UUID,p_application UUID,p_condition UUID,p_decision TEXT,
  p_reason TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_app loan_applications; v_condition loan_conditions; v_item loan_condition_evidence;
  v_set loan_condition_sets; v_event loan_application_events; v_hash TEXT; v_ready BOOLEAN;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.disburse') THEN
    RAISE EXCEPTION 'Missing financial.loans.disburse permission'; END IF;
  IF p_decision NOT IN ('satisfy','reject') OR length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 1000
    OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Condition decision evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-condition:'||p_condition::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.application_id<>p_application OR (v_event.evidence->>'condition_id')::UUID<>p_condition THEN
      RAISE EXCEPTION 'Idempotency key reused with different condition decision'; END IF;
    SELECT * INTO v_condition FROM loan_conditions WHERE id=p_condition AND organization_id=p_organization;
    RETURN jsonb_build_object('condition',to_jsonb(v_condition));
  END IF;
  SELECT * INTO v_app FROM loan_applications WHERE id=p_application AND organization_id=p_organization;
  SELECT * INTO v_condition FROM loan_conditions
    WHERE id=p_condition AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_item FROM loan_condition_evidence
    WHERE id=v_condition.current_evidence_id AND organization_id=p_organization FOR UPDATE;
  IF v_app.id IS NULL OR v_condition.id IS NULL OR v_condition.state<>'submitted' OR v_item.id IS NULL
    OR v_app.applicant_user_id=p_actor OR v_item.submitted_by=p_actor THEN
    RAISE EXCEPTION 'Independent condition decision is not permitted'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_condition::TEXT,v_item.id::TEXT,p_decision,
    btrim(p_reason),p_actor::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_condition_evidence SET state=CASE WHEN p_decision='satisfy' THEN 'satisfied' ELSE 'rejected' END,
    decided_by=p_actor,decision_reason=btrim(p_reason),decided_at=p_at WHERE id=v_item.id;
  UPDATE loan_conditions SET state=CASE WHEN p_decision='satisfy' THEN 'satisfied' ELSE 'rejected' END,
    satisfied_at=CASE WHEN p_decision='satisfy' THEN p_at ELSE NULL END WHERE id=p_condition
    RETURNING * INTO v_condition;
  SELECT NOT EXISTS(SELECT 1 FROM loan_conditions c WHERE c.condition_set_id=v_condition.condition_set_id
    AND c.state<>'satisfied') INTO v_ready;
  UPDATE loan_condition_sets SET state=CASE WHEN v_ready THEN 'ready' ELSE 'pending' END,
    ready_at=CASE WHEN v_ready THEN p_at ELSE NULL END WHERE id=v_condition.condition_set_id RETURNING * INTO v_set;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,
    request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,CASE WHEN p_decision='satisfy' THEN 'condition_satisfied' ELSE 'condition_rejected' END,
    p_actor,p_idempotency_key,v_hash,jsonb_build_object('condition_id',p_condition,
      'evidence_id',v_item.id,'condition_set_id',v_set.id,'condition_set_state',v_set.state),p_at);
  RETURN jsonb_build_object('condition',to_jsonb(v_condition),'condition_set',to_jsonb(v_set));
END $$;

CREATE OR REPLACE FUNCTION propose_loan_disbursement_destination(
  p_organization UUID,p_actor UUID,p_application UUID,p_provider_name TEXT,p_provider_environment TEXT,
  p_ciphertext TEXT,p_fingerprint TEXT,p_masked TEXT,p_account_name_masked TEXT,
  p_verification_snapshot JSONB,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_app loan_applications; v_destination loan_disbursement_destinations;
  v_event loan_application_events; v_hash TEXT;
BEGIN
  IF p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic','sandbox','live')
    OR length(COALESCE(p_ciphertext,'')) NOT BETWEEN 32 AND 4096
    OR COALESCE(p_fingerprint,'') !~ '^[a-f0-9]{64}$'
    OR length(COALESCE(p_masked,'')) NOT BETWEEN 4 AND 40
    OR length(btrim(COALESCE(p_account_name_masked,''))) NOT BETWEEN 2 AND 160
    OR jsonb_typeof(p_verification_snapshot)<>'object'
    OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Loan destination evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    SELECT * INTO v_destination FROM loan_disbursement_destinations
      WHERE id=(v_event.evidence->>'destination_id')::UUID AND organization_id=p_organization;
    IF v_event.application_id<>p_application OR v_destination.id IS NULL THEN
      RAISE EXCEPTION 'Idempotency key reused with different destination facts'; END IF;
    RETURN jsonb_build_object('destination',to_jsonb(v_destination)-'destination_ciphertext');
  END IF;
  SELECT * INTO v_app FROM loan_applications WHERE id=p_application AND organization_id=p_organization;
  IF v_app.id IS NULL OR v_app.state<>'accepted' OR NOT loan_actor_can_supply_condition(v_app,p_actor) THEN
    RAISE EXCEPTION 'Actor cannot propose this disbursement destination'; END IF;
  IF EXISTS(SELECT 1 FROM loan_disbursement_destinations WHERE organization_id=p_organization
    AND application_id=p_application AND state IN ('proposed','verified')) THEN
    RAISE EXCEPTION 'A current disbursement destination already exists'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_application::TEXT,p_provider_name,
    p_provider_environment,p_fingerprint,p_actor::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_disbursement_destinations(organization_id,application_id,provider_name,
    provider_environment,destination_ciphertext,destination_fingerprint,destination_masked,
    account_name_masked,verification_snapshot,verification_version,proposed_by,proposed_at)
  VALUES(p_organization,p_application,p_provider_name,p_provider_environment,p_ciphertext,p_fingerprint,
    p_masked,btrim(p_account_name_masked),p_verification_snapshot,'CRD-05.DESTINATION.1',p_actor,p_at)
  RETURNING * INTO v_destination;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,
    request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,'disbursement_destination_proposed',p_actor,p_idempotency_key,v_hash,
    jsonb_build_object('destination_id',v_destination.id,'destination_fingerprint',p_fingerprint,
      'provider_name',p_provider_name,'provider_environment',p_provider_environment),p_at);
  RETURN jsonb_build_object('destination',to_jsonb(v_destination)-'destination_ciphertext');
END $$;

CREATE OR REPLACE FUNCTION list_loan_applications(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_can_review BOOLEAN;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships
    WHERE organization_id=p_organization AND user_id=p_actor AND status='active')
  THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  v_can_review:=has_financial_permission(p_organization,p_actor,'financial.loans.review')
    OR has_financial_permission(p_organization,p_actor,'financial.loans.disburse');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'application',to_jsonb(application),
      'decisions',(SELECT COALESCE(jsonb_agg(to_jsonb(decision) ORDER BY decision.sequence),'[]'::JSONB)
        FROM loan_application_decisions decision WHERE decision.organization_id=p_organization
          AND decision.application_id=application.id),
      'adverse_review',(SELECT to_jsonb(review) FROM loan_adverse_reviews review
        WHERE review.organization_id=p_organization AND review.application_id=application.id),
      'offers',(SELECT COALESCE(jsonb_agg(to_jsonb(offer) ORDER BY offer.version),'[]'::JSONB)
        FROM loan_offers offer WHERE offer.organization_id=p_organization
          AND offer.application_id=application.id),
      'repayment_schedules',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'schedule',to_jsonb(schedule),
          'installments',(SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.sequence),'[]'::JSONB)
            FROM loan_repayment_installments item WHERE item.organization_id=p_organization
              AND item.schedule_id=schedule.id)
        ) ORDER BY schedule.version),'[]'::JSONB)
        FROM loan_repayment_schedules schedule WHERE schedule.organization_id=p_organization
          AND schedule.application_id=application.id),
      'condition_sets',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'condition_set',to_jsonb(condition_set),
          'conditions',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'condition',to_jsonb(condition),
              'evidence',(SELECT COALESCE(jsonb_agg(to_jsonb(evidence) ORDER BY evidence.attempt),'[]'::JSONB)
                FROM loan_condition_evidence evidence WHERE evidence.organization_id=p_organization
                  AND evidence.condition_id=condition.id)
            ) ORDER BY condition.sequence),'[]'::JSONB)
            FROM loan_conditions condition WHERE condition.organization_id=p_organization
              AND condition.condition_set_id=condition_set.id)
        ) ORDER BY condition_set.version),'[]'::JSONB)
        FROM loan_condition_sets condition_set WHERE condition_set.organization_id=p_organization
          AND condition_set.application_id=application.id),
      'disbursement_destinations',(SELECT COALESCE(jsonb_agg(
          to_jsonb(destination)-'destination_ciphertext' ORDER BY destination.proposed_at),'[]'::JSONB)
        FROM loan_disbursement_destinations destination WHERE destination.organization_id=p_organization
          AND destination.application_id=application.id),
      'disbursements',(SELECT COALESCE(jsonb_agg(to_jsonb(disbursement) ORDER BY disbursement.attempt),'[]'::JSONB)
        FROM loan_disbursements disbursement WHERE disbursement.organization_id=p_organization
          AND disbursement.application_id=application.id),
      'contracts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'contract',to_jsonb(contract),
          'due_installments',(SELECT COALESCE(jsonb_agg(to_jsonb(due_item) ORDER BY due_item.sequence),'[]'::JSONB)
            FROM loan_due_installments due_item WHERE due_item.organization_id=p_organization
              AND due_item.contract_id=contract.id)
        ) ORDER BY contract.activated_at),'[]'::JSONB)
        FROM loan_contracts contract WHERE contract.organization_id=p_organization
          AND contract.application_id=application.id),
      'disbursement_reconciliation_exceptions',(SELECT COALESCE(jsonb_agg(to_jsonb(exception)
          ORDER BY exception.detected_at),'[]'::JSONB)
        FROM loan_disbursement_reconciliation_exceptions exception
        JOIN loan_disbursements disbursement ON disbursement.id=exception.disbursement_id
        WHERE exception.organization_id=p_organization AND disbursement.application_id=application.id)
    ) ORDER BY application.created_at DESC)
    FROM loan_applications application WHERE application.organization_id=p_organization
      AND (v_can_review OR application.applicant_user_id=p_actor)),'[]'::JSONB);
END $$;

ALTER TABLE loan_condition_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_conditions ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_condition_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_disbursement_destinations ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_disbursements ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_due_installments ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_disbursement_reconciliation_exceptions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON loan_condition_sets,loan_conditions,loan_condition_evidence,
  loan_disbursement_destinations,loan_disbursements,loan_contracts,loan_due_installments,
  loan_disbursement_reconciliation_exceptions FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON loan_condition_sets,loan_conditions,loan_condition_evidence,
  loan_disbursement_destinations,loan_disbursements,loan_contracts,loan_due_installments,
  loan_disbursement_reconciliation_exceptions FROM service_role;
GRANT SELECT ON loan_condition_sets,loan_conditions,loan_condition_evidence,
  loan_disbursement_destinations,loan_disbursements,loan_contracts,loan_due_installments,
  loan_disbursement_reconciliation_exceptions TO service_role;

REVOKE ALL ON FUNCTION loan_actor_can_supply_condition(loan_applications,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION ensure_loan_disbursement_account(UUID,UUID,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION initialize_loan_conditions(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_loan_condition_evidence(UUID,UUID,UUID,UUID,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_loan_condition(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION propose_loan_disbursement_destination(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION begin_loan_disbursement(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION succeed_loan_disbursement_payout(UUID,TEXT,TEXT,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fail_loan_disbursement_payout(UUID,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_loan_late_payout_success(UUID,UUID,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION initialize_loan_conditions(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION submit_loan_condition_evidence(UUID,UUID,UUID,UUID,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decide_loan_condition(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION propose_loan_disbursement_destination(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION begin_loan_disbursement(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION succeed_loan_disbursement_payout(UUID,TEXT,TEXT,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION fail_loan_disbursement_payout(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION record_loan_late_payout_success(UUID,UUID,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,JSONB) TO service_role;

CREATE OR REPLACE FUNCTION decide_loan_disbursement_destination(
  p_organization UUID,p_actor UUID,p_application UUID,p_destination UUID,p_decision TEXT,
  p_reason TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_app loan_applications; v_destination loan_disbursement_destinations;
  v_event loan_application_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.disburse') THEN
    RAISE EXCEPTION 'Missing financial.loans.disburse permission'; END IF;
  IF p_decision NOT IN ('verify','reject') OR length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 1000
    OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Destination decision evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-destination:'||p_destination::TEXT,0));
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.application_id<>p_application OR (v_event.evidence->>'destination_id')::UUID<>p_destination THEN
      RAISE EXCEPTION 'Idempotency key reused with different destination decision'; END IF;
    SELECT * INTO v_destination FROM loan_disbursement_destinations
      WHERE id=p_destination AND organization_id=p_organization;
    RETURN jsonb_build_object('destination',to_jsonb(v_destination)-'destination_ciphertext');
  END IF;
  SELECT * INTO v_app FROM loan_applications WHERE id=p_application AND organization_id=p_organization;
  SELECT * INTO v_destination FROM loan_disbursement_destinations
    WHERE id=p_destination AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_app.id IS NULL OR v_destination.id IS NULL OR v_destination.state<>'proposed'
    OR v_app.applicant_user_id=p_actor OR v_destination.proposed_by=p_actor THEN
    RAISE EXCEPTION 'Independent destination decision is not permitted'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_destination::TEXT,p_decision,btrim(p_reason),
    p_actor::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  UPDATE loan_disbursement_destinations
    SET state=CASE WHEN p_decision='verify' THEN 'verified' ELSE 'rejected' END,
      decided_by=p_actor,decision_reason=btrim(p_reason),decided_at=p_at
    WHERE id=p_destination RETURNING * INTO v_destination;
  INSERT INTO loan_application_events(organization_id,application_id,action,actor_id,idempotency_key,
    request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,CASE WHEN p_decision='verify' THEN
    'disbursement_destination_verified' ELSE 'disbursement_destination_rejected' END,
    p_actor,p_idempotency_key,v_hash,jsonb_build_object('destination_id',p_destination,
      'destination_fingerprint',v_destination.destination_fingerprint),p_at);
  RETURN jsonb_build_object('destination',to_jsonb(v_destination)-'destination_ciphertext');
END $$;

REVOKE ALL ON FUNCTION decide_loan_disbursement_destination(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION decide_loan_disbursement_destination(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
