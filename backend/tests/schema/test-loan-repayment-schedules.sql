-- CRD-04 database contract: accepted-offer schedule generation, exact totals,
-- deterministic fee/interest allocation, tenant safety, and immutability.
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
  v_result JSONB;
  v_facts JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_applicant
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD04: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd04-reviewer-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test',
      'Schedule Reviewer','farmer') RETURNING id INTO v_reviewer;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_reviewer,'finance_manager',
      ARRAY['financial.loans.configure','financial.loans.review'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd04-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test',
      'Schedule Outsider','farmer') RETURNING id INTO v_outsider;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider','lenderName','Deterministic Schedule Lender',
    'providerCode','PROVIDER.CRD04','eligibleBorrowerTypes',jsonb_build_array('individual'),
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
    'disclosureVersion','CRD04.2026.1','disclosureContentHash',repeat('c',64));

  v_result:=create_loan_product_draft(v_org,v_applicant,'CRD04.INPUTS','CRD04 schedule credit','NGN',
    v_facts,'crd04-product-create-001','2026-08-11T09:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_applicant,v_product,1,
    'crd04-product-submit-001','2026-08-11T09:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_product,1,
    'crd04-product-approve-001','2026-08-11T09:02:00Z');

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',
    1000000,180,1000000,0,6,jsonb_build_array('income:test:schedule'),NULL,
    'CRD04.2026.1',repeat('c',64),'CRD-04.DECLARATION.1',repeat('d',64),
    'crd04-application-create-001','2026-08-11T09:03:00Z');
  v_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_application,
    'crd04-application-submit-001','2026-08-11T09:04:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_application,900000,180,75000,20000,995000,
    ARRAY['SIGNED_MANDATE_REQUIRED'],'CRD04.2026.1',repeat('c',64),'2026-08-20T10:00:00Z',
    ARRAY['MANUAL_REVIEW_APPROVED'],'Verified evidence supports this scheduled credit offer.',
    'crd04-offer-issue-001','2026-08-11T10:00:00Z');
  v_offer:=(v_result->'offer'->>'id')::UUID;
  v_offer_hash:=v_result->'offer'->>'offer_hash';
  PERFORM accept_loan_offer(v_org,v_applicant,v_application,v_offer,v_offer_hash,
    'CRD-04.ACCEPTANCE.1',repeat('e',64),'crd04-offer-accept-001','2026-08-11T10:01:00Z');

  v_failed:=FALSE;
  BEGIN
    PERFORM generate_loan_repayment_schedule(v_org,v_applicant,v_application,v_offer,
      'crd04-self-schedule-001','2026-08-11T10:02:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%independent schedule generation%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD04: applicant generated their own contractual schedule'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM generate_loan_repayment_schedule(v_org,v_outsider,v_application,v_offer,
      'crd04-outsider-schedule-001','2026-08-11T10:02:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Missing financial.loans.review permission%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD04: outsider generated a tenant schedule'; END IF;

  v_result:=generate_loan_repayment_schedule(v_org,v_reviewer,v_application,v_offer,
    'crd04-schedule-generate-001','2026-08-11T10:03:00Z');
  v_schedule:=(v_result->'schedule'->>'id')::UUID;
  IF (generate_loan_repayment_schedule(v_org,v_reviewer,v_application,v_offer,
    'crd04-schedule-generate-001','2026-08-11T10:04:00Z')->'schedule'->>'id')::UUID<>v_schedule
  THEN RAISE EXCEPTION 'CRD04: schedule replay was not idempotent'; END IF;

  IF (v_result->'schedule'->>'state')<>'contractual'
    OR (v_result->'schedule'->>'repayment_installment_count')::INTEGER<>6
    OR (v_result->'schedule'->>'upfront_item_count')::INTEGER<>1
    OR jsonb_array_length(v_result->'installments')<>7
    OR (v_result->'schedule'->>'schedule_hash') !~ '^[a-f0-9]{64}$'
  THEN RAISE EXCEPTION 'CRD04: schedule header or immutable snapshot is incomplete'; END IF;

  IF (SELECT SUM(principal_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>900000
    OR (SELECT SUM(interest_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>75000
    OR (SELECT SUM(fee_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>20000
    OR (SELECT SUM(total_due_minor) FROM loan_repayment_installments WHERE schedule_id=v_schedule)<>995000
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_schedule
      AND sequence=0 AND kind='upfront' AND due_offset_days=0 AND fee_due_minor=5000)
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_schedule
      AND sequence=6 AND kind='repayment' AND due_offset_days=187 AND closing_principal_minor=0)
  THEN RAISE EXCEPTION 'CRD04: schedule does not reconcile to the accepted offer'; END IF;

  IF EXISTS(
    SELECT 1 FROM (
      SELECT sequence,interest_due_minor,
        lag(interest_due_minor) OVER (ORDER BY sequence) AS previous_interest
      FROM loan_repayment_installments WHERE schedule_id=v_schedule AND kind='repayment'
    ) ordered_interest
    WHERE previous_interest IS NOT NULL AND interest_due_minor>previous_interest
  ) THEN RAISE EXCEPTION 'CRD04: reducing-balance interest is not monotonic'; END IF;

  IF position(v_schedule::TEXT IN list_loan_applications(v_org,v_applicant)::TEXT)=0
    OR NOT EXISTS(SELECT 1 FROM loan_application_events WHERE schedule_id=v_schedule
      AND action='repayment_schedule_generated')
    OR NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=v_org
      AND action='LOAN_REPAYMENT_SCHEDULE_GENERATED' AND resource_id=v_schedule::TEXT)
  THEN RAISE EXCEPTION 'CRD04: applicant visibility or durable evidence is incomplete'; END IF;

  v_facts:=v_facts||jsonb_build_object(
    'repaymentFrequency','bullet','interestMethod','zero_interest',
    'nominalAnnualRateBasisPoints',0,'aprBasisPoints',0,'effectiveAnnualCostBasisPoints',0,
    'fees','[]'::JSONB,'disclosureVersion','CRD04.ZERO.1','disclosureContentHash',repeat('f',64));
  v_result:=create_loan_product_draft(v_org,v_applicant,'CRD04.ZERO','CRD04 zero-interest bullet',
    'NGN',v_facts,'crd04-bullet-product-create-001','2026-08-11T11:00:00Z');
  v_bullet_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_applicant,v_bullet_product,1,
    'crd04-bullet-product-submit-001','2026-08-11T11:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_bullet_product,1,
    'crd04-bullet-product-approve-001','2026-08-11T11:02:00Z');
  v_result:=create_loan_application_draft(v_org,v_applicant,v_bullet_product,'individual',NULL,
    'farm_inputs',100000,30,1000000,0,6,jsonb_build_array('income:test:bullet'),NULL,
    'CRD04.ZERO.1',repeat('f',64),'CRD-04.DECLARATION.1',repeat('d',64),
    'crd04-bullet-application-create-001','2026-08-11T11:03:00Z');
  v_bullet_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_bullet_application,
    'crd04-bullet-application-submit-001','2026-08-11T11:04:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_bullet_application,100000,30,0,0,100000,
    ARRAY[]::TEXT[],'CRD04.ZERO.1',repeat('f',64),'2026-08-20T12:00:00Z',
    ARRAY['ZERO_INTEREST_APPROVED'],'Verified evidence supports this zero-interest bullet offer.',
    'crd04-bullet-offer-issue-001','2026-08-11T12:00:00Z');
  v_bullet_offer:=(v_result->'offer'->>'id')::UUID;
  PERFORM accept_loan_offer(v_org,v_applicant,v_bullet_application,v_bullet_offer,
    v_result->'offer'->>'offer_hash','CRD-04.ACCEPTANCE.1',repeat('e',64),
    'crd04-bullet-offer-accept-001','2026-08-11T12:01:00Z');
  v_result:=generate_loan_repayment_schedule(v_org,v_reviewer,v_bullet_application,v_bullet_offer,
    'crd04-bullet-schedule-001','2026-08-11T12:02:00Z');
  v_bullet_schedule:=(v_result->'schedule'->>'id')::UUID;
  IF (v_result->'schedule'->>'repayment_installment_count')::INTEGER<>1
    OR (v_result->'schedule'->>'interest_total_minor')::BIGINT<>0
    OR NOT EXISTS(SELECT 1 FROM loan_repayment_installments WHERE schedule_id=v_bullet_schedule
      AND sequence=1 AND due_offset_days=37 AND principal_due_minor=100000
      AND interest_due_minor=0 AND fee_due_minor=0 AND total_due_minor=100000
      AND closing_principal_minor=0)
  THEN RAISE EXCEPTION 'CRD04: zero-interest bullet schedule is incorrect'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN UPDATE loan_repayment_schedules SET generated_at=NOW();
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD04: service role directly mutated schedules'; END IF;
  v_failed:=FALSE;
  BEGIN DELETE FROM loan_repayment_installments;
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD04: service role directly deleted installments'; END IF;
END $$;
RESET ROLE;
