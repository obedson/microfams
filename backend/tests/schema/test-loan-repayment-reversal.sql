-- CRD-08 database contract: maker-checker zero-interest repayment correction,
-- exact linked journal reversal, replay, isolation, and state reconciliation.
SET search_path = public, extensions;

BEGIN;

DO $$
DECLARE
  v_org UUID;
  v_applicant UUID;
  v_reviewer UUID;
  v_outsider UUID;
  v_product UUID;
  v_application UUID;
  v_offer UUID;
  v_schedule UUID;
  v_destination UUID;
  v_disbursement UUID;
  v_payout UUID;
  v_contract loan_contracts;
  v_result JSONB;
  v_facts JSONB;
  v_repayment UUID;
  v_reversal UUID;
  v_reversal_journal UUID;
  v_correlation UUID:=gen_random_uuid();
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_applicant
    FROM organization_memberships
    WHERE status='active' AND role='owner'
    ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD06: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd06-reviewer-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test',
      'test','Repayment Reviewer','farmer')
    RETURNING id INTO v_reviewer;
  INSERT INTO organization_memberships(
    organization_id,user_id,role,permissions,status,joined_at
  ) VALUES(
    v_org,v_reviewer,'finance_manager',
    ARRAY['financial.loans.configure','financial.loans.review',
      'financial.loans.disburse','financial.loans.service_existing'],
    'active',NOW()
  );
  INSERT INTO users(email,password,name,role) VALUES
    ('crd06-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test',
      'test','Repayment Outsider','farmer')
    RETURNING id INTO v_outsider;

  IF NOT EXISTS(
    SELECT 1 FROM accounting_periods
    WHERE organization_id=v_org AND status='open'
      AND CURRENT_DATE BETWEEN starts_on AND ends_on
  ) THEN
    INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on)
    VALUES(v_org,'CRD06 current period',CURRENT_DATE-30,CURRENT_DATE+365);
  END IF;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider',
    'lenderName','Deterministic Repayment Lender',
    'providerCode','PROVIDER.CRD06',
    'eligibleBorrowerTypes',jsonb_build_array('individual'),
    'purposes',jsonb_build_array('farm_inputs'),
    'minimumPrincipalMinor',100000,
    'maximumPrincipalMinor',50000000,
    'minimumTenorDays',30,
    'maximumTenorDays',365,
    'repaymentFrequency','bullet',
    'interestMethod','zero_interest',
    'nominalAnnualRateBasisPoints',0,
    'aprBasisPoints',0,
    'effectiveAnnualCostBasisPoints',0,
    'fees','[]'::JSONB,
    'gracePeriodDays',7,
    'collateralRules',jsonb_build_object('required',FALSE),
    'guaranteeRules',jsonb_build_object('required',FALSE),
    'affordabilityRules',jsonb_build_object(
      'requiredIdentityTier','none',
      'minimumVerifiedIncomeMonths',3,
      'maximumDebtServiceRatioBasisPoints',7000
    ),
    'delinquencyStages',jsonb_build_array(
      jsonb_build_object('code','late','label','Late',
        'startsAfterDays',1,'classification','late'),
      jsonb_build_object('code','defaulted','label','Defaulted',
        'startsAfterDays',90,'classification','defaulted')
    ),
    'restructuringPolicy',jsonb_build_object(
      'allowed',TRUE,'independentApprovalRequired',TRUE
    ),
    'writeOffPolicy',jsonb_build_object(
      'eligibleAfterDaysPastDue',180,
      'independentApprovalRequired',TRUE
    ),
    'repaymentAllocationOrder',jsonb_build_array(
      'statutory_charges','collection_costs','penalties',
      'accrued_interest','principal'
    ),
    'penaltyCompoundingAllowed',FALSE,
    'penaltyCompoundingLegalBasis',NULL,
    'disclosureVersion','CRD06.ZERO.1',
    'disclosureContentHash',repeat('6',64)
  );

  v_result:=create_loan_product_draft(
    v_org,v_applicant,'CRD06.ZERO','CRD06 zero-fee repayment contract','NGN',
    v_facts,'crd06-product-create-001','2026-08-12T09:00:00Z'
  );
  v_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(
    v_org,v_applicant,v_product,1,
    'crd06-product-submit-001','2026-08-12T09:01:00Z'
  );
  PERFORM approve_loan_product_version(
    v_org,v_reviewer,v_product,1,
    'crd06-product-approve-001','2026-08-12T09:02:00Z'
  );

  v_result:=create_loan_application_draft(
    v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',
    100000,30,1000000,0,6,jsonb_build_array('income:test:crd06'),NULL,
    'CRD06.ZERO.1',repeat('6',64),
    'CRD-04.DECLARATION.1',repeat('d',64),
    'crd06-application-create-001','2026-08-12T09:03:00Z'
  );
  v_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(
    v_org,v_applicant,v_application,
    'crd06-application-submit-001','2026-08-12T09:04:00Z'
  );

  v_result:=issue_loan_offer(
    v_org,v_reviewer,v_application,100000,30,0,0,100000,
    ARRAY[]::TEXT[],'CRD06.ZERO.1',repeat('6',64),
    '2026-08-20T12:00:00Z',ARRAY['ZERO_INTEREST_APPROVED'],
    'Verified evidence supports this zero-fee repayment contract.',
    'crd06-offer-issue-001','2026-08-12T10:00:00Z'
  );
  v_offer:=(v_result->'offer'->>'id')::UUID;
  PERFORM accept_loan_offer(
    v_org,v_applicant,v_application,v_offer,
    v_result->'offer'->>'offer_hash',
    'CRD-04.ACCEPTANCE.1',repeat('e',64),
    'crd06-offer-accept-001','2026-08-12T10:01:00Z'
  );

  v_result:=generate_loan_repayment_schedule(
    v_org,v_reviewer,v_application,v_offer,
    'crd06-schedule-generate-001','2026-08-12T10:02:00Z'
  );
  v_schedule:=(v_result->'schedule'->>'id')::UUID;

  v_result:=initialize_loan_conditions(
    v_org,v_reviewer,v_application,v_offer,v_schedule,
    'crd06-condition-init-001','2026-08-12T10:03:00Z'
  );
  IF v_result->'condition_set'->>'state'<>'ready'
    OR jsonb_array_length(v_result->'conditions')<>0
  THEN RAISE EXCEPTION 'CRD06: zero-condition contract was not ready'; END IF;

  v_result:=propose_loan_disbursement_destination(
    v_org,v_applicant,v_application,'deterministic','deterministic',
    'v1.synthetic-crd06-ciphertext-without-cleartext-0123456789',
    repeat('7',64),'******0606','Re************er',
    jsonb_build_object(
      'version','CRD-05.DESTINATION.1',
      'providerName','deterministic',
      'providerEnvironment','deterministic',
      'accountNameHash',repeat('8',64)
    ),
    'crd06-destination-propose-001','2026-08-12T10:04:00Z'
  );
  v_destination:=(v_result->'destination'->>'id')::UUID;
  PERFORM decide_loan_disbursement_destination(
    v_org,v_reviewer,v_application,v_destination,'verify',
    'Destination ownership and provider evidence were independently verified.',
    'crd06-destination-verify-001','2026-08-12T10:05:00Z'
  );

  v_result:=begin_loan_disbursement(
    v_org,v_reviewer,v_application,v_destination,
    'deterministic','deterministic',
    'crd06-disbursement-begin-001',gen_random_uuid(),
    '2026-08-12T10:06:00Z'
  );
  v_disbursement:=(v_result->'disbursement'->>'id')::UUID;
  v_payout:=(v_result->'payout'->>'id')::UUID;
  PERFORM mark_payout_submitted(
    v_payout,repeat('9',64),'DET-CRD06-SUCCESS',FALSE
  );
  PERFORM succeed_loan_disbursement_payout(
    v_payout,
    (SELECT internal_reference FROM payouts WHERE id=v_payout),
    'DET-CRD06-SUCCESS',100000,'NGN',repeat('7',64),
    v_org,'deterministic','deterministic'
  );

  SELECT * INTO v_contract FROM loan_contracts
    WHERE organization_id=v_org AND application_id=v_application;
  IF v_contract.id IS NULL OR v_contract.state<>'active'
    OR v_contract.interest_contractual_minor<>0
    OR v_contract.fees_contractual_minor<>0
    OR v_contract.total_contractual_minor<>v_contract.principal_original_minor
  THEN RAISE EXCEPTION 'CRD06: zero-fee active contract fixture is invalid'; END IF;

  v_result:=record_loan_repayment(
    v_org,v_reviewer,v_application,v_contract.id,
    v_contract.principal_original_minor,CURRENT_DATE,v_correlation,
    'crd06-payoff-repayment-001'
  );
  v_repayment:=(v_result->'repayment'->>'id')::UUID;
  IF v_repayment IS NULL OR v_result->>'state'<>'paid_off'
    OR (v_result->>'principalOutstandingMinor')::BIGINT<>0
    OR (v_result->>'interestOutstandingMinor')::BIGINT<>0
    OR (SELECT principal_allocated_minor FROM loan_repayments
      WHERE id=v_repayment)<>v_contract.principal_original_minor
    OR (SELECT interest_allocated_minor FROM loan_repayments
      WHERE id=v_repayment)<>0
  THEN RAISE EXCEPTION 'CRD06: payoff allocation did not reconcile'; END IF;

  IF (record_loan_repayment(
      v_org,v_reviewer,v_application,v_contract.id,
      v_contract.principal_original_minor,CURRENT_DATE,v_correlation,
      'crd06-payoff-repayment-001'
    )->'repayment'->>'id')::UUID<>v_repayment
    OR (SELECT count(*) FROM loan_repayments
      WHERE organization_id=v_org
        AND idempotency_key='crd06-payoff-repayment-001')<>1
  THEN RAISE EXCEPTION 'CRD06: repayment replay was not idempotent'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM record_loan_repayment(
      v_org,v_reviewer,v_application,v_contract.id,
      v_contract.principal_original_minor,CURRENT_DATE,gen_random_uuid(),
      'crd06-payoff-repayment-001'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Idempotency key reused%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'CRD06: changed repayment replay was accepted';
  END IF;

  IF (SELECT SUM(CASE WHEN line.side='debit' THEN line.amount_minor ELSE 0 END)
      FROM journal_lines line JOIN loan_repayments repayment
        ON repayment.journal_entry_id=line.journal_entry_id
      WHERE repayment.id=v_repayment)<>v_contract.principal_original_minor
    OR (SELECT SUM(CASE WHEN line.side='credit' THEN line.amount_minor ELSE 0 END)
      FROM journal_lines line JOIN loan_repayments repayment
        ON repayment.journal_entry_id=line.journal_entry_id
      WHERE repayment.id=v_repayment)<>v_contract.principal_original_minor
  THEN RAISE EXCEPTION 'CRD06: repayment journal is not balanced'; END IF;

  IF (SELECT state FROM loan_contracts WHERE id=v_contract.id)<>'paid_off'
    OR (SELECT state FROM loan_applications WHERE id=v_application)<>'paid_off'
    OR NOT EXISTS(
      SELECT 1 FROM organization_audit_log
      WHERE organization_id=v_org
        AND action='LOAN_REPAYMENT_RECORDED'
        AND resource_id=v_repayment::TEXT
    )
  THEN RAISE EXCEPTION 'CRD06: payoff state or audit evidence did not reconcile'; END IF;

  v_result:=propose_loan_repayment_reversal(
    v_org,v_applicant,v_application,v_contract.id,v_repayment,
    'DUPLICATE_PAYMENT','Provider reconciliation proves this settlement was duplicated.',
    jsonb_build_array('reconciliation:crd08-duplicate-001'),gen_random_uuid(),
    'crd08-reversal-proposal-001','2026-08-13T10:00:00Z'
  );
  v_reversal:=(v_result->'reversal'->>'id')::UUID;
  IF v_reversal IS NULL OR v_result->'reversal'->>'state'<>'proposed'
  THEN RAISE EXCEPTION 'CRD08: reversal proposal was not recorded'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM decide_loan_repayment_reversal(
      v_org,v_applicant,v_reversal,'approve',
      'The proposal maker cannot independently approve this correction.',
      gen_random_uuid(),'crd08-maker-decision-rejected-001','2026-08-13T10:01:00Z'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Maker cannot approve%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD08: maker approved their own reversal'; END IF;

  v_result:=decide_loan_repayment_reversal(
    v_org,v_reviewer,v_reversal,'approve',
    'Independent reconciliation evidence confirms the duplicate settlement.',
    gen_random_uuid(),'crd08-reversal-approve-001','2026-08-13T10:02:00Z'
  );
  v_reversal_journal:=(v_result->'reversal'->>'reversal_journal_entry_id')::UUID;
  IF v_result->'reversal'->>'state'<>'approved' OR v_result->>'state'<>'active'
    OR v_reversal_journal IS NULL
    OR (SELECT state FROM loan_contracts WHERE id=v_contract.id)<>'active'
    OR (SELECT state FROM loan_applications WHERE id=v_application)<>'active'
    OR loan_contract_principal_outstanding(v_org,v_contract.id)<>v_contract.principal_original_minor
    OR (SELECT status FROM journal_entries WHERE id=(SELECT journal_entry_id FROM loan_repayments WHERE id=v_repayment))<>'reversed'
    OR (SELECT reversal_of_entry_id FROM journal_entries WHERE id=v_reversal_journal)
      IS DISTINCT FROM (SELECT journal_entry_id FROM loan_repayments WHERE id=v_repayment)
  THEN RAISE EXCEPTION 'CRD08: approved reversal did not reconcile'; END IF;

  IF (SELECT SUM(CASE WHEN original.side=reversed.side THEN 1 ELSE 0 END)
      FROM journal_lines original JOIN journal_lines reversed
        ON reversed.journal_entry_id=v_reversal_journal
        AND reversed.line_number=original.line_number
        AND reversed.account_id=original.account_id
        AND reversed.amount_minor=original.amount_minor
      WHERE original.journal_entry_id=(SELECT journal_entry_id FROM loan_repayments WHERE id=v_repayment))<>0
  THEN RAISE EXCEPTION 'CRD08: reversal journal did not invert original sides'; END IF;

  IF (decide_loan_repayment_reversal(
      v_org,v_reviewer,v_reversal,'approve',
      'Independent reconciliation evidence confirms the duplicate settlement.',
      (v_result->'reversal'->>'review_correlation_id')::UUID,
      'crd08-reversal-approve-001','2026-08-13T10:02:00Z'
    )->'reversal'->>'id')::UUID<>v_reversal
  THEN RAISE EXCEPTION 'CRD08: decision replay was not idempotent'; END IF;

  IF NOT EXISTS(SELECT 1 FROM organization_audit_log
      WHERE organization_id=v_org AND action='LOAN_REPAYMENT_REVERSAL_APPROVED'
        AND resource_id=v_reversal::TEXT)
    OR has_table_privilege('service_role','public.loan_repayment_reversals','UPDATE')
  THEN RAISE EXCEPTION 'CRD08: audit or immutability evidence is incomplete'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM record_loan_repayment(
      v_org,v_outsider,v_application,v_contract.id,1,
      CURRENT_DATE,gen_random_uuid(),'crd06-outsider-rejected-001'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Missing financial.loans.service_existing permission%'
      THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD06: outsider serviced a tenant loan'; END IF;

  IF has_table_privilege('service_role','public.loan_repayments','UPDATE')
    OR has_table_privilege('service_role','public.loan_repayments','DELETE')
  THEN RAISE EXCEPTION 'CRD06: service role can directly mutate repayments'; END IF;
END $$;

ROLLBACK;

SELECT 'loan repayment reversal schema tests passed' AS result;
