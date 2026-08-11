-- CRD-03 database contract: independent manual review, immutable offer
-- versions, exact acceptance, expiry, withdrawal, and tenant safety.
SET search_path = public, extensions;

DO $$
DECLARE
  v_org UUID;
  v_applicant UUID;
  v_reviewer UUID;
  v_outsider UUID;
  v_product UUID;
  v_accept_application UUID;
  v_decline_application UUID;
  v_expire_application UUID;
  v_withdraw_application UUID;
  v_offer_one UUID;
  v_offer_two UUID;
  v_expiring_offer UUID;
  v_withdraw_offer UUID;
  v_offer_hash TEXT;
  v_result JSONB;
  v_facts JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_applicant
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD03: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd03-reviewer-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Offer Reviewer','farmer')
    RETURNING id INTO v_reviewer;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_reviewer,'finance_manager',
      ARRAY['financial.loans.configure','financial.loans.review'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd03-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Offer Outsider','farmer')
    RETURNING id INTO v_outsider;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider','lenderName','Deterministic Test Lender','providerCode','PROVIDER.CRD03',
    'eligibleBorrowerTypes',jsonb_build_array('individual','group','organization'),
    'purposes',jsonb_build_array('farm_inputs','working_capital'),
    'minimumPrincipalMinor',100000,'maximumPrincipalMinor',50000000,'minimumTenorDays',30,'maximumTenorDays',365,
    'repaymentFrequency','monthly','interestMethod','reducing_balance','nominalAnnualRateBasisPoints',1800,
    'aprBasisPoints',1950,'effectiveAnnualCostBasisPoints',2100,
    'fees',jsonb_build_array(jsonb_build_object('code','origination_fee','label','Origination fee',
      'calculation','fixed','timing','disbursement','capitalized',TRUE,'amountMinor',20000)),
    'gracePeriodDays',7,
    'collateralRules',jsonb_build_object('required',FALSE),'guaranteeRules',jsonb_build_object('required',FALSE),
    'affordabilityRules',jsonb_build_object('requiredIdentityTier','none','minimumVerifiedIncomeMonths',3,
      'maximumDebtServiceRatioBasisPoints',7000),
    'delinquencyStages',jsonb_build_array(
      jsonb_build_object('code','late','label','Late','startsAfterDays',1,'classification','late'),
      jsonb_build_object('code','defaulted','label','Defaulted','startsAfterDays',90,'classification','defaulted')),
    'restructuringPolicy',jsonb_build_object('allowed',TRUE,'independentApprovalRequired',TRUE),
    'writeOffPolicy',jsonb_build_object('eligibleAfterDaysPastDue',180,'independentApprovalRequired',TRUE),
    'repaymentAllocationOrder',jsonb_build_array('statutory_charges','collection_costs','penalties','accrued_interest','principal'),
    'penaltyCompoundingAllowed',FALSE,'penaltyCompoundingLegalBasis',NULL,
    'disclosureVersion','CRD03.2026.1','disclosureContentHash',repeat('c',64));
  v_result:=create_loan_product_draft(v_org,v_applicant,'CRD03.INPUTS','CRD03 input credit','NGN',v_facts,
    'crd03-product-create-001','2026-08-11T09:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_applicant,v_product,1,'crd03-product-submit-001','2026-08-11T09:01:00Z');
  PERFORM approve_loan_product_version(v_org,v_reviewer,v_product,1,'crd03-product-approve-001','2026-08-11T09:02:00Z');

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',1000000,180,
    1000000,0,6,jsonb_build_array('income:test:accept'),NULL,'CRD03.2026.1',repeat('c',64),
    'CRD-03.DECLARATION.1',repeat('d',64),'crd03-accept-create-001','2026-08-11T09:03:00Z');
  v_accept_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_accept_application,'crd03-accept-submit-001','2026-08-11T09:04:00Z');

  v_result:=issue_loan_offer(v_org,v_reviewer,v_accept_application,900000,180,75000,20000,995000,
    ARRAY['SIGNED_MANDATE_REQUIRED'],'CRD03.2026.1',repeat('c',64),'2026-08-20T10:00:00Z',
    ARRAY['MANUAL_REVIEW_APPROVED'],'Verified evidence supports a bounded credit offer.',
    'crd03-offer-issue-001','2026-08-11T10:00:00Z');
  v_offer_one:=(v_result->'offer'->>'id')::UUID;
  IF (issue_loan_offer(v_org,v_reviewer,v_accept_application,900000,180,75000,20000,995000,
    ARRAY['SIGNED_MANDATE_REQUIRED'],'CRD03.2026.1',repeat('c',64),'2026-08-20T10:00:00Z',
    ARRAY['MANUAL_REVIEW_APPROVED'],'Verified evidence supports a bounded credit offer.',
    'crd03-offer-issue-001','2026-08-11T10:01:00Z')->'offer'->>'id')::UUID<>v_offer_one
  THEN RAISE EXCEPTION 'CRD03: offer replay was not idempotent'; END IF;

  v_result:=issue_loan_offer(v_org,v_reviewer,v_accept_application,850000,150,60000,20000,930000,
    ARRAY['SIGNED_MANDATE_REQUIRED','FARM_BUDGET_REQUIRED'],'CRD03.2026.1',repeat('c',64),'2026-08-21T10:00:00Z',
    ARRAY['OFFER_TERMS_REVISED'],'Updated farm budget supports the revised lower exposure.',
    'crd03-offer-revise-001','2026-08-12T10:00:00Z');
  v_offer_two:=(v_result->'offer'->>'id')::UUID;
  v_offer_hash:=v_result->'offer'->>'offer_hash';
  IF NOT EXISTS(SELECT 1 FROM loan_offers WHERE id=v_offer_one AND state='superseded' AND version=1)
    OR NOT EXISTS(SELECT 1 FROM loan_offers WHERE id=v_offer_two AND state='offered' AND version=2
      AND supersedes_offer_id=v_offer_one AND total_repayable_minor=930000)
  THEN RAISE EXCEPTION 'CRD03: material revision did not create an immutable new offer'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM accept_loan_offer(v_org,v_applicant,v_accept_application,v_offer_two,repeat('0',64),
      'CRD-03.ACCEPTANCE.1',repeat('e',64),'crd03-accept-wrong-hash-001','2026-08-13T10:00:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%offer hash does not match%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD03: applicant accepted a mismatched offer'; END IF;
  v_result:=accept_loan_offer(v_org,v_applicant,v_accept_application,v_offer_two,v_offer_hash,
    'CRD-03.ACCEPTANCE.1',repeat('e',64),'crd03-accept-valid-001','2026-08-13T10:01:00Z');
  IF v_result->'application'->>'state'<>'accepted' OR v_result->'offer'->>'state'<>'accepted'
    OR v_result->'offer'->>'acceptance_version'<>'CRD-03.ACCEPTANCE.1'
  THEN RAISE EXCEPTION 'CRD03: exact offer acceptance evidence is incomplete'; END IF;

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'working_capital',700000,120,
    900000,0,6,jsonb_build_array('income:test:decline'),NULL,'CRD03.2026.1',repeat('c',64),
    'CRD-03.DECLARATION.1',repeat('d',64),'crd03-decline-create-001','2026-08-11T11:00:00Z');
  v_decline_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_decline_application,'crd03-decline-submit-001','2026-08-11T11:01:00Z');
  v_failed:=FALSE;
  BEGIN
    PERFORM decline_loan_application(v_org,v_applicant,v_decline_application,
      ARRAY['UNVERIFIED_REPAYMENT_CAPACITY'],'Applicant must not review their own application.',
      'crd03-self-decline-001','2026-08-11T11:02:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%independent credit decision%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD03: applicant made their own credit decision'; END IF;
  v_result:=decline_loan_application(v_org,v_reviewer,v_decline_application,
    ARRAY['UNVERIFIED_REPAYMENT_CAPACITY'],'Evidence does not establish reliable repayment capacity.',
    'crd03-decline-valid-001','2026-08-11T11:03:00Z');
  IF v_result->'application'->>'state'<>'declined'
    OR v_result->'adverse_review'->>'notice_version'<>'CRD-03.ADVERSE.1'
    OR NOT EXISTS(SELECT 1 FROM loan_application_decisions WHERE application_id=v_decline_application
      AND stage='credit_review' AND result='fail' AND reviewer_id=v_reviewer
      AND review_reason='Evidence does not establish reliable repayment capacity.')
  THEN RAISE EXCEPTION 'CRD03: manual decline evidence is incomplete'; END IF;

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',600000,90,
    800000,0,6,jsonb_build_array('income:test:expire'),NULL,'CRD03.2026.1',repeat('c',64),
    'CRD-03.DECLARATION.1',repeat('d',64),'crd03-expire-create-001','2026-08-11T12:00:00Z');
  v_expire_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_expire_application,'crd03-expire-submit-001','2026-08-11T12:01:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_expire_application,600000,90,25000,20000,645000,
    ARRAY[]::TEXT[],'CRD03.2026.1',repeat('c',64),'2026-08-12T15:00:00Z',ARRAY['MANUAL_REVIEW_APPROVED'],
    'Verified evidence supports this time-bounded offer.','crd03-expire-offer-001','2026-08-11T13:00:00Z');
  v_expiring_offer:=(v_result->'offer'->>'id')::UUID;
  v_result:=expire_loan_offer(v_org,v_reviewer,v_expire_application,v_expiring_offer,
    'ACCEPTANCE_WINDOW_ELAPSED','crd03-expire-command-001','2026-08-12T15:01:00Z');
  IF v_result->'application'->>'state'<>'credit_review' OR v_result->'offer'->>'state'<>'expired'
  THEN RAISE EXCEPTION 'CRD03: expired offer did not return to review safely'; END IF;

  v_result:=create_loan_application_draft(v_org,v_applicant,v_product,'individual',NULL,'farm_inputs',500000,90,
    800000,0,6,jsonb_build_array('income:test:withdraw'),NULL,'CRD03.2026.1',repeat('c',64),
    'CRD-03.DECLARATION.1',repeat('d',64),'crd03-withdraw-create-001','2026-08-11T14:00:00Z');
  v_withdraw_application:=(v_result->'application'->>'id')::UUID;
  PERFORM submit_loan_application(v_org,v_applicant,v_withdraw_application,'crd03-withdraw-submit-001','2026-08-11T14:01:00Z');
  v_result:=issue_loan_offer(v_org,v_reviewer,v_withdraw_application,500000,90,20000,20000,540000,
    ARRAY[]::TEXT[],'CRD03.2026.1',repeat('c',64),'2026-08-20T15:00:00Z',ARRAY['MANUAL_REVIEW_APPROVED'],
    'Verified evidence supports this withdrawable offer.','crd03-withdraw-offer-001','2026-08-11T15:00:00Z');
  v_withdraw_offer:=(v_result->'offer'->>'id')::UUID;
  v_failed:=FALSE;
  BEGIN
    PERFORM withdraw_loan_application(v_org,v_applicant,v_withdraw_application,'APPLICANT_CHANGED_PLANS',
      'short','2026-08-11T15:01:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%evidence is invalid%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD03: withdrawal accepted an invalid idempotency key'; END IF;
  PERFORM withdraw_loan_application(v_org,v_applicant,v_withdraw_application,'APPLICANT_CHANGED_PLANS',
    'crd03-withdraw-command-001','2026-08-11T15:01:00Z');
  IF NOT EXISTS(SELECT 1 FROM loan_applications WHERE id=v_withdraw_application AND state='withdrawn')
    OR NOT EXISTS(SELECT 1 FROM loan_offers WHERE id=v_withdraw_offer AND state='withdrawn')
  THEN RAISE EXCEPTION 'CRD03: pre-acceptance withdrawal left an active offer'; END IF;

  v_failed:=FALSE;
  BEGIN PERFORM list_loan_applications(v_org,v_outsider);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%active organization member%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD03: outsider read tenant offer data'; END IF;
  IF (SELECT count(*) FROM loan_offers WHERE application_id=v_accept_application)<2
    OR jsonb_array_length(list_loan_applications(v_org,v_reviewer))<4
    OR (SELECT count(*) FROM organization_audit_log WHERE organization_id=v_org
      AND action IN ('LOAN_OFFER_ISSUED','LOAN_OFFER_REVISED','LOAN_OFFER_ACCEPTED',
        'LOAN_CREDIT_REVIEW_DECLINED','LOAN_OFFER_EXPIRED'))<7
  THEN RAISE EXCEPTION 'CRD03: offer history or audit evidence is incomplete'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN UPDATE loan_offers SET state='expired' WHERE state='offered';
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD03: service role directly mutated offers'; END IF;
END $$;
RESET ROLE;
