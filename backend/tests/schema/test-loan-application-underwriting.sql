-- CRD-02 database contract: immutable product/application facts, deterministic
-- decisions, explainable adverse notices, independent review, and tenant safety.
SET search_path = public, extensions;

DO $$
DECLARE
  v_org UUID;
  v_maker UUID;
  v_reviewer UUID;
  v_member UUID;
  v_outsider UUID;
  v_product UUID;
  v_pass UUID;
  v_declined UUID;
  v_member_application UUID;
  v_result JSONB;
  v_facts JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_maker
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD02: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd02-reviewer-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Credit Reviewer','farmer')
    RETURNING id INTO v_reviewer;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_reviewer,'finance_manager',ARRAY['financial.loans.configure','financial.loans.review'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd02-member-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Credit Applicant','farmer')
    RETURNING id INTO v_member;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_member,'member','{}','active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd02-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Credit Outsider','farmer')
    RETURNING id INTO v_outsider;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider','lenderName','Deterministic Test Lender','providerCode','PROVIDER.CRD02',
    'eligibleBorrowerTypes',jsonb_build_array('individual','group','organization'),
    'purposes',jsonb_build_array('farm_inputs','working_capital'),
    'minimumPrincipalMinor',100000,'maximumPrincipalMinor',50000000,'minimumTenorDays',30,'maximumTenorDays',365,
    'repaymentFrequency','monthly','interestMethod','reducing_balance','nominalAnnualRateBasisPoints',1800,
    'aprBasisPoints',1950,'effectiveAnnualCostBasisPoints',2100,'fees','[]'::JSONB,'gracePeriodDays',7,
    'collateralRules',jsonb_build_object('required',FALSE),'guaranteeRules',jsonb_build_object('required',FALSE),
    'affordabilityRules',jsonb_build_object('requiredIdentityTier','none','minimumVerifiedIncomeMonths',3,
      'maximumDebtServiceRatioBasisPoints',5000),
    'delinquencyStages',jsonb_build_array(
      jsonb_build_object('code','late','label','Late','startsAfterDays',1,'classification','late'),
      jsonb_build_object('code','defaulted','label','Defaulted','startsAfterDays',90,'classification','defaulted')),
    'restructuringPolicy',jsonb_build_object('allowed',TRUE,'independentApprovalRequired',TRUE),
    'writeOffPolicy',jsonb_build_object('eligibleAfterDaysPastDue',180,'independentApprovalRequired',TRUE),
    'repaymentAllocationOrder',jsonb_build_array('statutory_charges','collection_costs','penalties','accrued_interest','principal'),
    'penaltyCompoundingAllowed',FALSE,'penaltyCompoundingLegalBasis',NULL,
    'disclosureVersion','CRD02.2026.1','disclosureContentHash',repeat('c',64));

  v_result:=create_loan_product_draft(v_org,v_maker,'CRD02.INPUTS','CRD02 input credit','NGN',v_facts,
    'crd02-product-create-001','2026-08-11T09:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_maker,v_product,1,'crd02-product-submit-001','2026-08-11T09:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_product,1,'crd02-product-approve-001','2026-08-11T09:02:00Z');

  v_result:=create_loan_application_draft(v_org,v_maker,v_product,'individual',NULL,'farm_inputs',1000000,180,
    1000000,0,6,jsonb_build_array('income:test:maker-pass'),NULL,'CRD02.2026.1',repeat('c',64),
    'CRD-02.DECLARATION.1',repeat('d',64),'crd02-pass-create-001','2026-08-11T09:03:00Z');
  v_pass:=(v_result->'application'->>'id')::UUID;
  IF (create_loan_application_draft(v_org,v_maker,v_product,'individual',NULL,'farm_inputs',1000000,180,
    1000000,0,6,jsonb_build_array('income:test:maker-pass'),NULL,'CRD02.2026.1',repeat('c',64),
    'CRD-02.DECLARATION.1',repeat('d',64),'crd02-pass-create-001','2026-08-11T09:03:01Z')->'application'->>'id')::UUID<>v_pass
  THEN RAISE EXCEPTION 'CRD02: draft replay was not idempotent'; END IF;
  v_result:=submit_loan_application(v_org,v_maker,v_pass,'crd02-pass-submit-001','2026-08-11T09:04:00Z');
  IF v_result->'application'->>'state'<>'credit_review'
    OR (SELECT count(*) FROM loan_application_decisions WHERE application_id=v_pass)<>3
    OR EXISTS(SELECT 1 FROM loan_application_decisions WHERE application_id=v_pass AND result NOT IN ('pass','manual_review'))
  THEN RAISE EXCEPTION 'CRD02: eligible application did not reach evidenced credit review'; END IF;

  v_result:=create_loan_application_draft(v_org,v_maker,v_product,'individual',NULL,'farm_inputs',1000000,180,
    200000,150000,6,jsonb_build_array('income:test:maker-adverse'),NULL,'CRD02.2026.1',repeat('c',64),
    'CRD-02.DECLARATION.1',repeat('d',64),'crd02-decline-create-001','2026-08-11T09:05:00Z');
  v_declined:=(v_result->'application'->>'id')::UUID;
  v_result:=submit_loan_application(v_org,v_maker,v_declined,'crd02-decline-submit-001','2026-08-11T09:06:00Z');
  IF v_result->'application'->>'state'<>'declined'
    OR NOT EXISTS(SELECT 1 FROM loan_application_decisions WHERE application_id=v_declined
      AND stage='affordability' AND result='fail' AND 'DEBT_SERVICE_RATIO_EXCEEDED'=ANY(reason_codes))
    OR NOT EXISTS(SELECT 1 FROM loan_adverse_reviews WHERE application_id=v_declined AND state='eligible'
      AND notice_version='CRD-02.ADVERSE.1' AND notice_content_hash='090c52c3fe0939973ba615d1f62259a626cca772c8d26884805e0ba294f25850')
  THEN RAISE EXCEPTION 'CRD02: adverse decision evidence is incomplete'; END IF;

  PERFORM request_loan_adverse_review(v_org,v_maker,v_declined,
    'The submitted income evidence should receive independent human review.',jsonb_build_array('income:test:amended'),
    'crd02-review-request-001','2026-08-11T09:07:00Z');
  v_failed:=FALSE;
  BEGIN
    PERFORM decide_loan_adverse_review(v_org,v_maker,v_declined,'reopen',
      'The applicant must not review their own adverse outcome.','crd02-review-self-001','2026-08-11T09:08:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%independent decision%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD02: applicant decided their own adverse review'; END IF;
  v_result:=decide_loan_adverse_review(v_org,v_reviewer,v_declined,'reopen',
    'The amended income evidence warrants a complete manual credit review.','crd02-review-decide-001','2026-08-11T09:09:00Z');
  IF v_result->'application'->>'state'<>'credit_review' OR v_result->'adverse_review'->>'state'<>'reopened'
    OR NOT EXISTS(SELECT 1 FROM loan_application_decisions WHERE application_id=v_declined
      AND stage='human_adverse_review' AND result='overridden' AND reviewer_id=v_reviewer)
  THEN RAISE EXCEPTION 'CRD02: independent adverse review did not preserve the override'; END IF;

  v_result:=create_loan_application_draft(v_org,v_member,v_product,'individual',NULL,'working_capital',500000,90,
    300000,0,5,jsonb_build_array('income:test:member'),NULL,'CRD02.2026.1',repeat('c',64),
    'CRD-02.DECLARATION.1',repeat('d',64),'crd02-member-create-001','2026-08-11T09:10:00Z');
  v_member_application:=(v_result->'application'->>'id')::UUID;
  IF jsonb_array_length(list_loan_applications(v_org,v_member))<>1 THEN
    RAISE EXCEPTION 'CRD02: ordinary applicant could infer another application'; END IF;
  IF jsonb_array_length(list_loan_applications(v_org,v_reviewer))<>3 THEN
    RAISE EXCEPTION 'CRD02: permitted review queue is incomplete'; END IF;
  PERFORM withdraw_loan_application(v_org,v_member,v_member_application,'APPLICANT_CHANGED_PLANS',
    'crd02-member-withdraw-001','2026-08-11T09:11:00Z');
  IF NOT EXISTS(SELECT 1 FROM loan_applications WHERE id=v_member_application AND state='withdrawn')
  THEN RAISE EXCEPTION 'CRD02: applicant withdrawal was not recorded'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM create_loan_application_draft(v_org,v_member,v_product,'organization',v_org,'farm_inputs',500000,90,
      300000,0,5,'[]'::JSONB,NULL,'CRD02.2026.1',repeat('c',64),'CRD-02.DECLARATION.1',repeat('d',64),
      'crd02-unauthorized-org-001','2026-08-11T09:12:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%delegated authority%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD02: unauthorized organization application was accepted'; END IF;
  v_failed:=FALSE;
  BEGIN PERFORM list_loan_applications(v_org,v_outsider);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%active organization member%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD02: outsider read tenant underwriting data'; END IF;

  IF NOT EXISTS(SELECT 1 FROM loan_applications WHERE id=v_pass AND product_version=1
      AND disclosure_version='CRD02.2026.1' AND disclosure_content_hash=repeat('c',64)
      AND product_rule_snapshot->'version'->>'disclosure_version'='CRD02.2026.1')
    OR (SELECT count(*) FROM organization_audit_log WHERE organization_id=v_org
      AND action IN ('LOAN_APPLICATION_DRAFTED','LOAN_APPLICATION_SCREENED','LOAN_ADVERSE_REVIEW_REQUESTED',
        'LOAN_ADVERSE_REVIEW_REOPENED','LOAN_APPLICATION_WITHDRAWN'))<8
  THEN RAISE EXCEPTION 'CRD02: immutable facts or audit evidence are incomplete'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO loan_applications(organization_id,product_id,product_version_id,product_version,applicant_user_id,
      borrower_type,borrower_user_id,purpose,requested_principal_minor,requested_tenor_days,currency,
      monthly_net_income_minor,monthly_existing_debt_minor,verified_income_months,disclosure_version,
      disclosure_content_hash,declaration_version,declaration_content_hash,declaration_accepted_at,
      product_rule_snapshot,creation_key,creation_hash)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),1,gen_random_uuid(),'individual',gen_random_uuid(),
      'farm_inputs',100000,30,'NGN',100000,0,1,'x',repeat('a',64),'x',repeat('b',64),NOW(),'{}','forged-crd02-key',repeat('c',64));
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD02: service role directly inserted an application'; END IF;
END $$;
RESET ROLE;
