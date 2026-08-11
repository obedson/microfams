-- CRD-01 database contract: tenant isolation, immutable rule snapshots,
-- idempotency, version replacement, exact disclosure evidence, and maker-checker.
SET search_path = public, extensions;

DO $$
DECLARE
  v_org UUID;
  v_maker UUID;
  v_checker UUID;
  v_outsider UUID;
  v_product UUID;
  v_version_one UUID;
  v_version_two UUID;
  v_result JSONB;
  v_facts JSONB;
  v_revised JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_maker
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CRD01: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('crd-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Credit Checker','farmer')
    RETURNING id INTO v_checker;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_checker,'finance_manager',ARRAY['financial.loans.configure'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('crd-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Credit Outsider','farmer')
    RETURNING id INTO v_outsider;

  v_facts:=jsonb_build_object(
    'lenderType','licensed_provider','lenderName','Test Lending Partner','providerCode','PROVIDER.TEST',
    'eligibleBorrowerTypes',jsonb_build_array('individual','group'),'purposes',jsonb_build_array('farm_inputs','working_capital'),
    'minimumPrincipalMinor',100000,'maximumPrincipalMinor',50000000,'minimumTenorDays',30,'maximumTenorDays',365,
    'repaymentFrequency','monthly','interestMethod','reducing_balance','nominalAnnualRateBasisPoints',1800,
    'aprBasisPoints',1950,'effectiveAnnualCostBasisPoints',2100,
    'fees',jsonb_build_array(jsonb_build_object('code','origination_fee','label','Origination fee','calculation','percentage',
      'rateBasisPoints',100,'timing','disbursement','capitalized',FALSE)),
    'gracePeriodDays',7,'collateralRules',jsonb_build_object('required',FALSE),
    'guaranteeRules',jsonb_build_object('required',TRUE,'minimumGuarantors',1),
    'affordabilityRules',jsonb_build_object('maximumDebtServiceRatioBasisPoints',4000,'minimumVerifiedIncomeMonths',3),
    'delinquencyStages',jsonb_build_array(
      jsonb_build_object('code','late','label','Late','startsAfterDays',1,'classification','late'),
      jsonb_build_object('code','delinquent','label','Delinquent','startsAfterDays',30,'classification','delinquent'),
      jsonb_build_object('code','defaulted','label','Defaulted','startsAfterDays',90,'classification','defaulted')),
    'restructuringPolicy',jsonb_build_object('allowed',TRUE,'maximumRestructures',1,'independentApprovalRequired',TRUE),
    'writeOffPolicy',jsonb_build_object('eligibleAfterDaysPastDue',180,'independentApprovalRequired',TRUE,'collectionContinues',TRUE),
    'repaymentAllocationOrder',jsonb_build_array('statutory_charges','collection_costs','penalties','accrued_interest','principal'),
    'penaltyCompoundingAllowed',FALSE,'penaltyCompoundingLegalBasis',NULL,
    'disclosureVersion','2026.1','disclosureContentHash',repeat('a',64));

  v_result:=create_loan_product_draft(v_org,v_maker,'CRD.INPUTS','Seasonal input credit','NGN',v_facts,
    'crd-product-create-001','2026-08-11T08:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  v_version_one:=(v_result->'version'->>'id')::UUID;
  IF v_product IS NULL OR v_result->'version'->>'disclosure_version'<>'2026.1' THEN
    RAISE EXCEPTION 'CRD01: draft did not preserve the exact disclosure';
  END IF;
  IF (create_loan_product_draft(v_org,v_maker,'CRD.INPUTS','Seasonal input credit','NGN',v_facts,
    'crd-product-create-001','2026-08-11T08:00:01Z')->'product'->>'id')::UUID<>v_product
  THEN RAISE EXCEPTION 'CRD01: create replay was not idempotent'; END IF;
  v_failed:=FALSE;
  BEGIN
    PERFORM create_loan_product_draft(v_org,v_maker,'CRD.INPUTS','Changed product facts','NGN',v_facts,
      'crd-product-create-001','2026-08-11T08:00:02Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%different loan product facts%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD01: an idempotency key was reused with different facts'; END IF;

  PERFORM submit_loan_product_version(v_org,v_maker,v_product,1,'crd-product-submit-001','2026-08-11T08:01:00Z');
  v_failed:=FALSE;
  BEGIN
    PERFORM approve_loan_product_version(v_org,v_maker,v_product,1,'crd-product-self-approve-001','2026-08-11T08:02:00Z');
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Maker cannot approve%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD01: maker approved their own product'; END IF;
  PERFORM approve_loan_product_version(v_org,v_checker,v_product,1,'crd-product-approve-001','2026-08-11T08:03:00Z');

  IF jsonb_array_length(list_active_loan_products(v_org,v_maker))<>1 THEN RAISE EXCEPTION 'CRD01: active product read is incomplete'; END IF;
  v_failed:=FALSE;
  BEGIN PERFORM list_active_loan_products(v_org,v_outsider);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not an active organization member%' THEN v_failed:=TRUE; END IF; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD01: cross-tenant product read was accepted'; END IF;

  v_revised:=jsonb_set(jsonb_set(v_facts,'{disclosureVersion}','"2026.2"'),'{disclosureContentHash}',to_jsonb(repeat('b',64)));
  v_result:=revise_loan_product(v_org,v_maker,v_product,1,v_revised,'crd-product-revise-001','2026-08-11T08:04:00Z');
  v_version_two:=(v_result->'version'->>'id')::UUID;
  PERFORM submit_loan_product_version(v_org,v_maker,v_product,2,'crd-product-submit-002','2026-08-11T08:05:00Z');
  PERFORM approve_loan_product_version(v_org,v_checker,v_product,2,'crd-product-approve-002','2026-08-11T08:06:00Z');

  IF NOT EXISTS(SELECT 1 FROM loan_products WHERE id=v_product AND organization_id=v_org AND state='active' AND current_version=2)
    OR NOT EXISTS(SELECT 1 FROM loan_product_versions WHERE id=v_version_one AND state='retired' AND disclosure_content_hash=repeat('a',64))
    OR NOT EXISTS(SELECT 1 FROM loan_product_versions WHERE id=v_version_two AND state='active' AND disclosure_content_hash=repeat('b',64))
  THEN RAISE EXCEPTION 'CRD01: approved revision did not replace the active version immutably'; END IF;
  IF jsonb_array_length(list_governed_loan_products(v_org,v_checker))<>1 THEN RAISE EXCEPTION 'CRD01: governed history is incomplete'; END IF;
  IF (SELECT count(*) FROM organization_audit_log WHERE organization_id=v_org AND action IN (
      'LOAN_PRODUCT_DRAFTED','LOAN_PRODUCT_SUBMITTED','LOAN_PRODUCT_APPROVED','LOAN_PRODUCT_REVISION_DRAFTED'))<>6
  THEN RAISE EXCEPTION 'CRD01: lifecycle audit evidence is incomplete'; END IF;
  IF NOT EXISTS(SELECT 1 FROM feature_flags WHERE key='financial.loans.read' AND default_enabled)
    OR NOT EXISTS(SELECT 1 FROM feature_flags WHERE key='financial.loans.configure' AND NOT default_enabled)
  THEN RAISE EXCEPTION 'CRD01: loan read/configure flags are not safely seeded'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO loan_products(organization_id,code,name,currency,created_by,creation_key,creation_hash)
      VALUES(gen_random_uuid(),'CRD.FORGE','Forged loan product','NGN',gen_random_uuid(),'forged-loan-key',repeat('a',64));
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'CRD01: service role directly inserted a loan product'; END IF;
END $$;
RESET ROLE;
