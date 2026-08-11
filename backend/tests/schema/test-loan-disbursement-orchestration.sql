-- CRD-05 database contract: conditions precedent, maker-checker destination
-- verification, provider-confirmed activation, ledger posting, due dates,
-- failure recovery, late-success reconciliation, and tenant immutability.
SET search_path = public, extensions;

DO $$
DECLARE
  v_org UUID;
  v_applicant UUID;
  v_reviewer UUID;
  v_outsider UUID;
  v_product UUID;
  v_bullet_product UUID;
  v_application UUID;
  v_bullet_application UUID;
  v_offer UUID;
  v_bullet_offer UUID;
  v_offer_hash TEXT;
  v_schedule UUID;
  v_bullet_schedule UUID;
  v_condition_set UUID;
  v_condition UUID;
  v_destination UUID;
  v_disbursement UUID;
  v_payout UUID;
  v_contract UUID;
  v_bullet_condition_set UUID;
  v_bullet_destination UUID;
  v_bullet_disbursement UUID;
  v_bullet_payout UUID;
  v_result JSONB;
  v_facts JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_applicant
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD05BASE: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd05-base-reviewer-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test',
      'Schedule Reviewer','farmer') RETURNING id INTO v_reviewer;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_reviewer,'finance_manager',
      ARRAY['financial.loans.configure','financial.loans.review','financial.loans.disburse'],
      'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd05-base-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test',
      'Schedule Outsider','farmer') RETURNING id INTO v_outsider;

  IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE organization_id=v_org
    AND status='open' AND CURRENT_DATE BETWEEN starts_on AND ends_on) THEN
    INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on)
    VALUES(v_org,'CRD05 current period',CURRENT_DATE-30,CURRENT_DATE+365);
  END IF;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider','lenderName','Deterministic Schedule Lender',
    'providerCode','PROVIDER.CRD05BASE','eligibleBorrowerTypes',jsonb_build_array('individual'),
    'purposes',jsonb_build_array('farm_inputs'),'minimumPrincipalMinor',100000,
    'maximumPrincipalMinor',50000000,'minimumTenorDays',30,'maximumTenorDays',365,
    'repaymentFrequency','monthly','interestMethod','reducing_balance',
    'nominalAnnualRateBasisPoints',1800,'aprBasisPoints',1950,
    'effectiveAnnualCostBasisPoints',2100,
    'fees',jsonb_build_array(
      jsonb_build_object('code','application_fee','label','Application fee','calculation','fixed',
        'timing','application','capitalized',FALSE,'amountMinor',5000),
      jsonb_build_object('code','origination_fee','label','Origination fee','calculation','fixed',
        'timing','disbursement','capitalized',TRUE,'amountMinor',15000)),
    'gracePeriodDays',7,'collateralRules',jsonb_build_object('required',FALSE),
    'guaranteeRules',jsonb_build_object('required',FALSE),
    'affordabilityRules',jsonb_build_object('requiredIdentityTier','none',
      'minimumVerifiedIncomeMonths',3,'maximumDebtServiceRatioBasisPoints',7000),
    'delinquencyStages',jsonb_build_array(
      jsonb_build_object('code','late','label','Late','startsAfterDays',1,'classification','late'),
      jsonb_build_object('code','defaulted','label','Defaulted','startsAfterDays',90,
        'classification','defaulted')),
    'restructuringPolicy',jsonb_build_object('allowed',TRUE,'independentApprovalRequired',TRUE),
    'writeOffPolicy',jsonb_build_object('eligibleAfterDaysPastDue',180,
      'independentApprovalRequired',TRUE),
    'repaymentAllocationOrder',jsonb_build_array('statutory_charges','collection_costs',
      'penalties','accrued_interest','principal'),
    'penaltyCompoundingAllowed',FALSE,'penaltyCompoundingLegalBasis',NULL,
    'disclosureVersion','CRD05BASE.2026.1','disclosureContentHash',repeat('c',64));

  v_result:=create_loan_product_draft(v_org,v_applicant,'CRD05BASE.INPUTS','CRD05BASE schedule credit','NGN',
    v_facts,'crd05-base-product-create-001','2026-08-11T09:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_applicant,v_product,1,
    'crd05-base-product-submit-001','2026-08-11T09:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_product,1,
    'crd05-base-product-approve-001','2026-08-11T09:02:00Z');

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',
    1000000,180,1000000,0,6,jsonb_build_array('income:test:schedule'),NULL,
    'CRD05BASE.2026.1',repeat('c',64),'CRD-04.DECLARATION.1',repeat('d',64),
    'crd05-base-application-create-001','2026-08-11T09:03:00Z');
  v_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_application,
    'crd05-base-application-submit-001','2026-08-11T09:04:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_application,900000,180,75000,20000,995000,
    ARRAY['SIGNED_MANDATE_REQUIRED'],'CRD05BASE.2026.1',repeat('c',64),'2026-08-20T10:00:00Z',
    ARRAY['MANUAL_REVIEW_APPROVED'],'Verified evidence supports this scheduled credit offer.',
    'crd05-base-offer-issue-001','2026-08-11T10:00:00Z');
  v_offer:=(v_result->'offer'->>'id')::UUID;
  v_offer_hash:=v_result->'offer'->>'offer_hash';
  PERFORM accept_loan_offer(v_org,v_applicant,v_application,v_offer,v_offer_hash,
    'CRD-04.ACCEPTANCE.1',repeat('e',64),'crd05-base-offer-accept-001','2026-08-11T10:01:00Z');

  v_failed:=FALSE;
  BEGIN
    PERFORM generate_loan_repayment_schedule(v_org,v_applicant,v_application,v_offer,
      'crd05-base-self-schedule-001','2026-08-11T10:02:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%independent schedule generation%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05BASE: applicant generated their own contractual schedule'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM generate_loan_repayment_schedule(v_org,v_outsider,v_application,v_offer,
      'crd05-base-outsider-schedule-001','2026-08-11T10:02:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Missing financial.loans.review permission%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05BASE: outsider generated a tenant schedule'; END IF;

  v_result:=generate_loan_repayment_schedule(v_org,v_reviewer,v_application,v_offer,
    'crd05-base-schedule-generate-001','2026-08-11T10:03:00Z');
  v_schedule:=(v_result->'schedule'->>'id')::UUID;
  IF (generate_loan_repayment_schedule(v_org,v_reviewer,v_application,v_offer,
    'crd05-base-schedule-generate-001','2026-08-11T10:04:00Z')->'schedule'->>'id')::UUID<>v_schedule
  THEN RAISE EXCEPTION 'CRD05BASE: schedule replay was not idempotent'; END IF;

  IF (v_result->'schedule'->>'state')<>'contractual'
    OR (v_result->'schedule'->>'repayment_installment_count')::INTEGER<>6
    OR (v_result->'schedule'->>'upfront_item_count')::INTEGER<>1
    OR jsonb_array_length(v_result->'installments')<>7
    OR (v_result->'schedule'->>'schedule_hash') !~ '^[a-f0-9]{64}$'
  THEN RAISE EXCEPTION 'CRD05BASE: schedule header or immutable snapshot is incomplete'; END IF;

  IF (SELECT SUM(principal_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>900000
    OR (SELECT SUM(interest_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>75000
    OR (SELECT SUM(fee_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>20000
    OR (SELECT SUM(total_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>995000
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_schedule
      AND sequence=0 AND kind='upfront' AND due_offset_days=0 AND fee_due_minor=5000)
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_schedule
      AND sequence=6 AND kind='repayment' AND due_offset_days=187 AND closing_principal_minor=0)
  THEN RAISE EXCEPTION 'CRD05BASE: schedule does not reconcile to the accepted offer'; END IF;

  IF EXISTS(
    SELECT 1 FROM (
      SELECT sequence,interest_due_minor,
        lag(interest_due_minor) OVER (ORDER BY sequence) AS previous_interest
      FROM loan_repayment_installments WHERE schedule_id=v_schedule AND kind='repayment'
    ) ordered_interest
    WHERE previous_interest IS NOT NULL AND interest_due_minor>previous_interest
  ) THEN RAISE EXCEPTION 'CRD05BASE: reducing-balance interest is not monotonic'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM initialize_loan_conditions(v_org,v_applicant,v_application,v_offer,v_schedule,
      'crd05-self-condition-init-001','2026-08-11T10:04:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Missing financial.loans.disburse permission%'
      OR SQLERRM LIKE '%independent condition initialization%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05: applicant initialized controlled conditions'; END IF;

  v_result:=initialize_loan_conditions(v_org,v_reviewer,v_application,v_offer,v_schedule,
    'crd05-condition-init-001','2026-08-11T10:04:00Z');
  v_condition_set:=(v_result->'condition_set'->>'id')::UUID;
  v_condition:=(v_result->'conditions'->0->>'id')::UUID;
  IF v_result->'condition_set'->>'state'<>'pending'
    OR v_result->'condition_set'->>'rules_version'<>'CRD-05.CONDITIONS.1'
    OR (v_result->'condition_set'->>'rules_hash') !~ '^[a-f0-9]{64}$'
  THEN RAISE EXCEPTION 'CRD05: versioned condition set is incomplete'; END IF;

  PERFORM submit_loan_condition_evidence(v_org,v_applicant,v_application,v_condition,
    jsonb_build_array('mandate:test:signed:001'),'crd05-condition-evidence-001',
    '2026-08-11T10:05:00Z');
  v_failed:=FALSE;
  BEGIN
    PERFORM decide_loan_condition(v_org,v_applicant,v_application,v_condition,'satisfy',
      'The applicant cannot verify their own condition evidence.',
      'crd05-self-condition-decision-001','2026-08-11T10:06:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Missing financial.loans.disburse permission%'
      OR SQLERRM LIKE '%Independent condition decision%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05: applicant verified their own condition'; END IF;
  v_result:=decide_loan_condition(v_org,v_reviewer,v_application,v_condition,'satisfy',
    'Signed mandate evidence was independently verified against the accepted offer.',
    'crd05-condition-decision-001','2026-08-11T10:07:00Z');
  IF v_result->'condition_set'->>'state'<>'ready'
    OR v_result->'condition'->>'state'<>'satisfied'
  THEN RAISE EXCEPTION 'CRD05: satisfied conditions did not make the set ready'; END IF;

  v_result:=propose_loan_disbursement_destination(v_org,v_applicant,v_application,
    'deterministic','deterministic','v1.synthetic-test-ciphertext-without-cleartext-0123',
    repeat('1',64),'******6789','Ve************er',
    jsonb_build_object('version','CRD-05.DESTINATION.1','providerName','deterministic',
      'providerEnvironment','deterministic','accountNameHash',repeat('2',64)),
    'crd05-destination-propose-001','2026-08-11T10:08:00Z');
  v_destination:=(v_result->'destination'->>'id')::UUID;
  IF v_result::TEXT LIKE '%synthetic-test-ciphertext%' THEN
    RAISE EXCEPTION 'CRD05: destination ciphertext leaked through the command response'; END IF;
  PERFORM decide_loan_disbursement_destination(v_org,v_reviewer,v_application,v_destination,'verify',
    'Destination ownership and provider verification evidence were independently confirmed.',
    'crd05-destination-verify-001','2026-08-11T10:09:00Z');

  v_result:=begin_loan_disbursement(v_org,v_reviewer,v_application,v_destination,
    'deterministic','deterministic','crd05-disbursement-begin-001',gen_random_uuid(),
    '2026-08-11T10:10:00Z');
  v_disbursement:=(v_result->'disbursement'->>'id')::UUID;
  v_payout:=(v_result->'payout'->>'id')::UUID;
  IF v_result->'disbursement'->>'state'<>'processing'
    OR v_result->'payout'->>'source_type'<>'loan_disbursement'
    OR EXISTS(SELECT 1 FROM loan_contracts WHERE application_id=v_application)
    OR EXISTS(SELECT 1 FROM journal_entries WHERE source_domain='loans.disbursement'
      AND source_record_id=v_disbursement::TEXT)
  THEN RAISE EXCEPTION 'CRD05: pre-confirmation disbursement created financial exposure'; END IF;

  PERFORM mark_payout_submitted(v_payout,repeat('3',64),'DET-CRD05-SUCCESS',FALSE);
  PERFORM succeed_loan_disbursement_payout(v_payout,
    (SELECT internal_reference FROM payouts WHERE id=v_payout),'DET-CRD05-SUCCESS',900000,'NGN',
    repeat('1',64),v_org,'deterministic','deterministic');
  SELECT id INTO v_contract FROM loan_contracts WHERE application_id=v_application;
  IF v_contract IS NULL OR (SELECT state FROM loan_applications WHERE id=v_application)<>'active'
    OR (SELECT state FROM loan_disbursements WHERE id=v_disbursement)<>'succeeded'
    OR (SELECT count(*) FROM loan_due_installments WHERE contract_id=v_contract)<>7
    OR NOT EXISTS(SELECT 1 FROM loan_due_installments due_item
      JOIN loan_contracts contract ON contract.id=due_item.contract_id
      WHERE due_item.contract_id=v_contract AND due_item.sequence=6
        AND due_item.due_on=contract.confirmed_disbursement_at::DATE+187)
    OR (SELECT SUM(CASE WHEN line.side='debit' THEN line.amount_minor ELSE 0 END)
        FROM journal_lines line JOIN loan_contracts contract
          ON contract.activation_journal_entry_id=line.journal_entry_id
        WHERE contract.id=v_contract)<>900000
    OR (SELECT SUM(CASE WHEN line.side='credit' THEN line.amount_minor ELSE 0 END)
        FROM journal_lines line JOIN loan_contracts contract
          ON contract.activation_journal_entry_id=line.journal_entry_id
        WHERE contract.id=v_contract)<>900000
  THEN RAISE EXCEPTION 'CRD05: confirmed activation, ledger, or materialized due dates are incorrect'; END IF;

  IF position(v_schedule::TEXT IN list_loan_applications(v_org,v_applicant)::TEXT)=0
    OR NOT EXISTS(SELECT 1 FROM loan_application_events WHERE schedule_id=v_schedule
      AND action='repayment_schedule_generated')
    OR NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=v_org
      AND action='LOAN_REPAYMENT_SCHEDULE_GENERATED' AND resource_id=v_schedule::TEXT)
  THEN RAISE EXCEPTION 'CRD05BASE: applicant visibility or durable evidence is incomplete'; END IF;

  v_facts:=v_facts||jsonb_build_object(
    'repaymentFrequency','bullet','interestMethod','zero_interest',
    'nominalAnnualRateBasisPoints',0,'aprBasisPoints',0,'effectiveAnnualCostBasisPoints',0,
    'fees','[]'::JSONB,'disclosureVersion','CRD05BASE.ZERO.1','disclosureContentHash',repeat('f',64));
  v_result:=create_loan_product_draft(v_org,v_applicant,'CRD05BASE.ZERO','CRD05BASE zero-interest bullet',
    'NGN',v_facts,'crd05-base-bullet-product-create-001','2026-08-11T11:00:00Z');
  v_bullet_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_applicant,v_bullet_product,1,
    'crd05-base-bullet-product-submit-001','2026-08-11T11:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_bullet_product,1,
    'crd05-base-bullet-product-approve-001','2026-08-11T11:02:00Z');
  v_result:=create_loan_application_draft(v_org,v_applicant,v_bullet_product,'individual',NULL,
    'farm_inputs',100000,30,1000000,0,6,jsonb_build_array('income:test:bullet'),NULL,
    'CRD05BASE.ZERO.1',repeat('f',64),'CRD-04.DECLARATION.1',repeat('d',64),
    'crd05-base-bullet-application-create-001','2026-08-11T11:03:00Z');
  v_bullet_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_bullet_application,
    'crd05-base-bullet-application-submit-001','2026-08-11T11:04:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_bullet_application,100000,30,0,0,100000,
    ARRAY[]::TEXT[],'CRD05BASE.ZERO.1',repeat('f',64),'2026-08-20T12:00:00Z',
    ARRAY['ZERO_INTEREST_APPROVED'],'Verified evidence supports this zero-interest bullet offer.',
    'crd05-base-bullet-offer-issue-001','2026-08-11T12:00:00Z');
  v_bullet_offer:=(v_result->'offer'->>'id')::UUID;
  PERFORM accept_loan_offer(v_org,v_applicant,v_bullet_application,v_bullet_offer,
    v_result->'offer'->>'offer_hash','CRD-04.ACCEPTANCE.1',repeat('e',64),
    'crd05-base-bullet-offer-accept-001','2026-08-11T12:01:00Z');
  v_result:=generate_loan_repayment_schedule(v_org,v_reviewer,v_bullet_application,v_bullet_offer,
    'crd05-base-bullet-schedule-001','2026-08-11T12:02:00Z');
  v_bullet_schedule:=(v_result->'schedule'->>'id')::UUID;
  IF (v_result->'schedule'->>'repayment_installment_count')::INTEGER<>1
    OR (v_result->'schedule'->>'interest_total_minor')::BIGINT<>0
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_bullet_schedule
      AND sequence=1 AND due_offset_days=37 AND principal_due_minor=100000
      AND interest_due_minor=0 AND fee_due_minor=0 AND total_due_minor=100000
      AND closing_principal_minor=0)
  THEN RAISE EXCEPTION 'CRD05BASE: zero-interest bullet schedule is incorrect'; END IF;

  v_result:=initialize_loan_conditions(v_org,v_reviewer,v_bullet_application,v_bullet_offer,
    v_bullet_schedule,'crd05-bullet-condition-init-001','2026-08-11T12:03:00Z');
  v_bullet_condition_set:=(v_result->'condition_set'->>'id')::UUID;
  IF v_result->'condition_set'->>'state'<>'ready'
    OR jsonb_array_length(v_result->'conditions')<>0 THEN
    RAISE EXCEPTION 'CRD05: empty approved condition set was not immediately ready'; END IF;
  v_result:=propose_loan_disbursement_destination(v_org,v_applicant,v_bullet_application,
    'deterministic','deterministic','v1.synthetic-bullet-ciphertext-without-cleartext-4567',
    repeat('4',64),'******4321','Bu************er',
    jsonb_build_object('version','CRD-05.DESTINATION.1','providerName','deterministic',
      'providerEnvironment','deterministic','accountNameHash',repeat('5',64)),
    'crd05-bullet-destination-propose-001','2026-08-11T12:04:00Z');
  v_bullet_destination:=(v_result->'destination'->>'id')::UUID;
  PERFORM decide_loan_disbursement_destination(v_org,v_reviewer,v_bullet_application,
    v_bullet_destination,'verify','Bullet destination evidence was independently verified.',
    'crd05-bullet-destination-verify-001','2026-08-11T12:05:00Z');
  v_result:=begin_loan_disbursement(v_org,v_reviewer,v_bullet_application,v_bullet_destination,
    'deterministic','deterministic','crd05-bullet-disbursement-begin-001',gen_random_uuid(),
    '2026-08-11T12:06:00Z');
  v_bullet_disbursement:=(v_result->'disbursement'->>'id')::UUID;
  v_bullet_payout:=(v_result->'payout'->>'id')::UUID;
  PERFORM mark_payout_submitted(v_bullet_payout,repeat('6',64),'DET-CRD05-FAILED',FALSE);
  PERFORM fail_loan_disbursement_payout(v_bullet_payout,'PROVIDER_REJECTED','Synthetic provider rejection');
  IF (SELECT state FROM loan_applications WHERE id=v_bullet_application)<>'accepted'
    OR EXISTS(SELECT 1 FROM loan_contracts WHERE application_id=v_bullet_application)
    OR EXISTS(SELECT 1 FROM journal_entries WHERE source_domain='loans.disbursement'
      AND source_record_id=v_bullet_disbursement::TEXT)
  THEN RAISE EXCEPTION 'CRD05: failed provider attempt created or retained financial exposure'; END IF;
  v_result:=record_loan_late_payout_success(v_bullet_payout,v_org,'DET-CRD05-LATE-SUCCESS',
    100000,'NGN',repeat('4',64),'deterministic','deterministic',
    jsonb_build_object('source','schema_contract','status','succeeded'));
  IF v_result->>'state'<>'open'
    OR (SELECT state FROM loan_disbursements WHERE id=v_bullet_disbursement)<>'reconciliation_required'
    OR (SELECT state FROM loan_applications WHERE id=v_bullet_application)<>'disbursement_pending'
    OR EXISTS(SELECT 1 FROM loan_contracts WHERE application_id=v_bullet_application)
  THEN RAISE EXCEPTION 'CRD05: late success was not quarantined for reconciliation'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN UPDATE loan_repayment_schedules SET generated_at=NOW();
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05BASE: service role directly mutated schedules'; END IF;
  v_failed:=FALSE;
  BEGIN DELETE FROM loan_repayment_installments;
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05BASE: service role directly deleted installments'; END IF;
  v_failed:=FALSE;
  BEGIN UPDATE loan_disbursements SET state='succeeded';
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05: service role directly mutated disbursements'; END IF;
  v_failed:=FALSE;
  BEGIN DELETE FROM loan_contracts;
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD05: service role directly deleted loan contracts'; END IF;
END $$;
RESET ROLE;
