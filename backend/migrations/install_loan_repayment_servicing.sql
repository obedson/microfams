-- CRD-06: governed servicing for existing zero-fee loan contracts.
-- Contractual fee allocation remains closed until an approved ordering rule
-- extends the five disclosed repayment buckets.

SET search_path = public, extensions;

INSERT INTO financial_account_purpose_rules(
  purpose,account_class,normal_side,allowed_owner_types,is_control
) VALUES
  ('loan_interest_receivable','asset','debit',ARRAY['loan_contract'],TRUE),
  ('loan_interest_revenue','revenue','credit',ARRAY['loan_contract'],FALSE),
  ('loan_repayment_clearing','asset','debit',ARRAY['loan_contract'],TRUE)
ON CONFLICT (purpose) DO NOTHING;

UPDATE organization_memberships SET permissions=(
  SELECT ARRAY(SELECT DISTINCT permission FROM unnest(
    COALESCE(permissions,'{}')||ARRAY['financial.loans.service_existing']
  ) permission)
) WHERE role='owner';

CREATE OR REPLACE FUNCTION ensure_loan_repayment_owner_permission()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.role='owner'
    AND NOT ('financial.loans.service_existing'=ANY(COALESCE(NEW.permissions,'{}')))
  THEN
    NEW.permissions:=array_append(
      COALESCE(NEW.permissions,'{}'),'financial.loans.service_existing'
    );
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER ensure_loan_repayment_owner_permission_trigger
  BEFORE INSERT OR UPDATE OF role,permissions ON organization_memberships
  FOR EACH ROW EXECUTE FUNCTION ensure_loan_repayment_owner_permission();

CREATE TABLE loan_repayments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  amount_minor BIGINT NOT NULL CHECK (amount_minor>0),
  currency VARCHAR(3) NOT NULL CHECK (currency~'^[A-Z]{3}$'),
  effective_date DATE NOT NULL,
  principal_allocated_minor BIGINT NOT NULL CHECK (principal_allocated_minor>=0),
  interest_allocated_minor BIGINT NOT NULL CHECK (interest_allocated_minor>=0),
  statutory_charges_allocated_minor BIGINT NOT NULL DEFAULT 0
    CHECK (statutory_charges_allocated_minor=0),
  collection_costs_allocated_minor BIGINT NOT NULL DEFAULT 0
    CHECK (collection_costs_allocated_minor=0),
  penalties_allocated_minor BIGINT NOT NULL DEFAULT 0
    CHECK (penalties_allocated_minor=0),
  allocation_order TEXT[] NOT NULL CHECK (cardinality(allocation_order)=5),
  allocation_snapshot JSONB NOT NULL CHECK (jsonb_typeof(allocation_snapshot)='object'),
  journal_entry_id UUID NOT NULL UNIQUE,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash~'^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  recorded_by UUID NOT NULL REFERENCES users(id),
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (application_id,organization_id)
    REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (contract_id,organization_id)
    REFERENCES loan_contracts(id,organization_id),
  FOREIGN KEY (journal_entry_id,organization_id,currency)
    REFERENCES journal_entries(id,organization_id,currency),
  UNIQUE (organization_id,idempotency_key),
  UNIQUE (id,organization_id),
  CHECK (amount_minor=principal_allocated_minor+interest_allocated_minor
    +statutory_charges_allocated_minor+collection_costs_allocated_minor
    +penalties_allocated_minor)
);

CREATE INDEX idx_loan_repayments_contract
  ON loan_repayments(organization_id,contract_id,recorded_at,id);

CREATE OR REPLACE FUNCTION require_loan_repayment_engine()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_repayment_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Loan repayments are immutable outside the servicing engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;

CREATE TRIGGER loan_repayments_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON loan_repayments
  FOR EACH ROW EXECUTE FUNCTION require_loan_repayment_engine();

CREATE OR REPLACE FUNCTION loan_contract_principal_outstanding(
  p_organization UUID,p_contract UUID
) RETURNS BIGINT LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT contract.principal_original_minor-COALESCE(SUM(repayment.principal_allocated_minor),0)
  FROM loan_contracts contract
  LEFT JOIN loan_repayments repayment
    ON repayment.organization_id=contract.organization_id
    AND repayment.contract_id=contract.id
  WHERE contract.organization_id=p_organization AND contract.id=p_contract
  GROUP BY contract.id,contract.principal_original_minor;
$$;

CREATE OR REPLACE FUNCTION loan_contract_interest_outstanding(
  p_organization UUID,p_contract UUID
) RETURNS BIGINT LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT contract.interest_contractual_minor-COALESCE(SUM(repayment.interest_allocated_minor),0)
  FROM loan_contracts contract
  LEFT JOIN loan_repayments repayment
    ON repayment.organization_id=contract.organization_id
    AND repayment.contract_id=contract.id
  WHERE contract.organization_id=p_organization AND contract.id=p_contract
  GROUP BY contract.id,contract.interest_contractual_minor;
$$;

CREATE OR REPLACE FUNCTION record_loan_repayment(
  p_organization UUID,p_actor UUID,p_application UUID,p_contract UUID,
  p_amount_minor BIGINT,p_effective_date DATE,p_correlation UUID,
  p_idempotency_key TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  v_contract loan_contracts;
  v_offer loan_offers;
  v_existing loan_repayments;
  v_principal_outstanding BIGINT;
  v_interest_outstanding BIGINT;
  v_accrued_interest_outstanding BIGINT;
  v_total_outstanding BIGINT;
  v_remaining BIGINT;
  v_principal BIGINT:=0;
  v_interest BIGINT:=0;
  v_bucket TEXT;
  v_hash TEXT;
  v_key TEXT;
  v_interest_receivable UUID;
  v_interest_revenue UUID;
  v_clearing UUID;
  v_lines JSONB:='[]'::JSONB;
  v_line INTEGER:=1;
  v_journal UUID;
  v_repayment loan_repayments;
  v_snapshot JSONB;
  v_after_principal BIGINT;
  v_after_interest BIGINT;
BEGIN
  IF NOT has_financial_permission(
    p_organization,p_actor,'financial.loans.service_existing'
  ) THEN RAISE EXCEPTION 'Missing financial.loans.service_existing permission'; END IF;
  IF p_amount_minor IS NULL OR p_amount_minor<=0 OR p_effective_date IS NULL
    OR p_correlation IS NULL OR p_idempotency_key IS NULL
    OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'Loan repayment request evidence is invalid'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization::TEXT||':loan-contract:'||p_contract::TEXT,0
  ));
  SELECT * INTO v_existing FROM loan_repayments
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,
      p_actor::TEXT,p_application::TEXT,p_contract::TEXT,p_amount_minor::TEXT,
      p_effective_date::TEXT,p_correlation::TEXT,p_idempotency_key),'UTF8'),'sha256'),'hex');
    IF v_existing.contract_id<>p_contract OR v_existing.application_id<>p_application
      OR v_existing.request_hash<>v_hash
    THEN RAISE EXCEPTION 'Idempotency key reused with different repayment facts'; END IF;
    RETURN jsonb_build_object('repayment',to_jsonb(v_existing),
      'principalOutstandingMinor',loan_contract_principal_outstanding(p_organization,p_contract),
      'interestOutstandingMinor',loan_contract_interest_outstanding(p_organization,p_contract));
  END IF;

  SELECT * INTO v_contract FROM loan_contracts
    WHERE id=p_contract AND application_id=p_application
      AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE id=v_contract.offer_id AND application_id=p_application
      AND organization_id=p_organization;
  IF v_contract.id IS NULL OR v_offer.id IS NULL
    OR v_contract.state NOT IN ('active','delinquent')
  THEN RAISE EXCEPTION 'Loan contract is not eligible for repayment servicing'; END IF;
  IF v_contract.fees_contractual_minor<>0 THEN
    RAISE EXCEPTION 'Contractual fee allocation requires an approved repayment ordering rule';
  END IF;

  v_principal_outstanding:=loan_contract_principal_outstanding(p_organization,p_contract);
  v_interest_outstanding:=loan_contract_interest_outstanding(p_organization,p_contract);
  SELECT GREATEST(COALESCE(SUM(due_item.interest_due_minor),0)
    -COALESCE((SELECT SUM(repayment.interest_allocated_minor)
      FROM loan_repayments repayment
      WHERE repayment.organization_id=p_organization
        AND repayment.contract_id=p_contract),0),0)
  INTO v_accrued_interest_outstanding
  FROM loan_due_installments due_item
  WHERE due_item.organization_id=p_organization
    AND due_item.contract_id=p_contract
    AND due_item.due_on<=p_effective_date;
  IF v_principal_outstanding<0 OR v_interest_outstanding<0 THEN
    RAISE EXCEPTION 'Loan repayment history does not reconcile with the contract'; END IF;
  v_total_outstanding:=v_principal_outstanding+v_accrued_interest_outstanding;
  IF p_amount_minor>v_total_outstanding THEN
    RAISE EXCEPTION 'Loan repayment exceeds the outstanding payoff amount'; END IF;

  v_remaining:=p_amount_minor;
  FOREACH v_bucket IN ARRAY v_offer.repayment_allocation_order LOOP
    IF v_bucket='accrued_interest' THEN
      v_interest:=LEAST(v_remaining,v_accrued_interest_outstanding);
      v_remaining:=v_remaining-v_interest;
    ELSIF v_bucket='principal' THEN
      v_principal:=LEAST(v_remaining,v_principal_outstanding);
      v_remaining:=v_remaining-v_principal;
    ELSIF v_bucket NOT IN ('statutory_charges','collection_costs','penalties') THEN
      RAISE EXCEPTION 'Loan repayment allocation order is unsupported';
    END IF;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'Loan repayment could not be fully allocated'; END IF;

  v_key:=upper(substr(md5(v_contract.id::TEXT),1,12));
  v_clearing:=ensure_loan_disbursement_account(p_organization,p_actor,
    'loan_contract',v_contract.id,'L.'||v_key||'.REPAYCLEAR','Loan repayment clearing',
    'loan_repayment_clearing',v_contract.currency,'loan-repay-clearing-'||v_contract.id::TEXT);
  IF v_contract.interest_contractual_minor>0 THEN
    v_interest_receivable:=ensure_loan_disbursement_account(p_organization,p_actor,
      'loan_contract',v_contract.id,'L.'||v_key||'.INTERESTREC','Loan interest receivable',
      'loan_interest_receivable',v_contract.currency,'loan-interest-rec-'||v_contract.id::TEXT);
    v_interest_revenue:=ensure_loan_disbursement_account(p_organization,p_actor,
      'loan_contract',v_contract.id,'L.'||v_key||'.INTERESTREV','Loan interest revenue',
      'loan_interest_revenue',v_contract.currency,'loan-interest-rev-'||v_contract.id::TEXT);
  END IF;
  IF v_interest>0 THEN
    v_hash:=encode(digest(convert_to(
      concat_ws('|',v_contract.id::TEXT,'interest-recognition',
        p_idempotency_key,v_interest::TEXT,p_effective_date::TEXT),
      'UTF8'),'sha256'),'hex');
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_interest_receivable,'line_number',1,
        'side','debit','amount_minor',v_interest,
        'memo','Recognize accrued loan interest receivable'),
      jsonb_build_object('account_id',v_interest_revenue,'line_number',2,
        'side','credit','amount_minor',v_interest,
        'memo','Recognize accrued loan interest revenue')
    );
    PERFORM post_financial_journal(p_organization,v_contract.currency,p_effective_date,
      'loans.interest_recognition',p_contract::TEXT,
      'loan-interest-'||p_idempotency_key,v_hash,p_correlation,
      'Recognize accrued loan interest',p_actor,v_lines);
  END IF;

  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,
    p_actor::TEXT,p_application::TEXT,p_contract::TEXT,p_amount_minor::TEXT,
    p_effective_date::TEXT,p_correlation::TEXT,p_idempotency_key),'UTF8'),'sha256'),'hex');
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_clearing,'line_number',v_line,
      'side','debit','amount_minor',p_amount_minor,'memo','Settled loan repayment')
  );
  v_line:=v_line+1;
  IF v_interest>0 THEN
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
      'account_id',v_interest_receivable,'line_number',v_line,'side','credit',
      'amount_minor',v_interest,'memo','Loan repayment allocated to interest'));
    v_line:=v_line+1;
  END IF;
  IF v_principal>0 THEN
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
      'account_id',v_contract.principal_receivable_account_id,'line_number',v_line,
      'side','credit','amount_minor',v_principal,
      'memo','Loan repayment allocated to principal'));
  END IF;
  v_journal:=post_financial_journal(p_organization,v_contract.currency,p_effective_date,
    'loans.repayment',p_contract::TEXT,p_idempotency_key,v_hash,p_correlation,
    'Record settled loan repayment',p_actor,v_lines);

  v_after_principal:=v_principal_outstanding-v_principal;
  v_after_interest:=v_interest_outstanding-v_interest;
  v_snapshot:=jsonb_build_object('allocationVersion','CRD-06.ALLOCATION.1',
    'order',to_jsonb(v_offer.repayment_allocation_order),
    'before',jsonb_build_object('principalMinor',v_principal_outstanding,
      'interestMinor',v_interest_outstanding),
    'allocated',jsonb_build_object('statutoryChargesMinor',0,
      'collectionCostsMinor',0,'penaltiesMinor',0,'interestMinor',v_interest,
      'principalMinor',v_principal),
    'after',jsonb_build_object('principalMinor',v_after_principal,
      'interestMinor',v_after_interest));
  PERFORM set_config('microfams.loan_repayment_engine','on',TRUE);
  INSERT INTO loan_repayments(organization_id,application_id,contract_id,
    amount_minor,currency,effective_date,principal_allocated_minor,
    interest_allocated_minor,allocation_order,allocation_snapshot,
    journal_entry_id,idempotency_key,request_hash,correlation_id,recorded_by)
  VALUES(p_organization,p_application,p_contract,p_amount_minor,v_contract.currency,
    p_effective_date,v_principal,v_interest,v_offer.repayment_allocation_order,
    v_snapshot,v_journal,p_idempotency_key,v_hash,p_correlation,p_actor)
  RETURNING * INTO v_repayment;

  IF v_after_principal=0 AND v_after_interest=0 THEN
    PERFORM set_config('microfams.loan_application_engine','on',TRUE);
    UPDATE loan_contracts SET state='paid_off' WHERE id=p_contract;
    UPDATE loan_applications SET state='paid_off',updated_at=NOW()
      WHERE id=p_application AND organization_id=p_organization;
  END IF;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,
    resource_type,resource_id,after_value)
  VALUES(p_organization,p_actor,'LOAN_REPAYMENT_RECORDED','loan_repayment',
    v_repayment.id::TEXT,jsonb_build_object('contract_id',p_contract,
      'amount_minor',p_amount_minor,'journal_entry_id',v_journal,
      'allocation',v_snapshot));
  RETURN jsonb_build_object('repayment',to_jsonb(v_repayment),
    'principalOutstandingMinor',v_after_principal,
    'interestOutstandingMinor',v_after_interest,
    'state',CASE WHEN v_after_principal=0 AND v_after_interest=0
      THEN 'paid_off' ELSE v_contract.state END);
END $$;

REVOKE INSERT,UPDATE,DELETE ON loan_repayments FROM service_role;
GRANT SELECT ON loan_repayments TO service_role;
REVOKE ALL ON FUNCTION record_loan_repayment(
  UUID,UUID,UUID,UUID,BIGINT,DATE,UUID,TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION record_loan_repayment(
  UUID,UUID,UUID,UUID,BIGINT,DATE,UUID,TEXT
) TO service_role;
REVOKE ALL ON FUNCTION loan_contract_principal_outstanding(UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION loan_contract_interest_outstanding(UUID,UUID) FROM PUBLIC;
