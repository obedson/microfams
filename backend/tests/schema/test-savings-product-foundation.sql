-- Savings product foundation contract: tenant isolation, maker-checker approval,
-- exact disclosure acceptance, idempotency, and canonical account provisioning.
SET search_path = public, extensions;

DO $$
DECLARE
  v_org UUID;
  v_maker UUID;
  v_checker UUID;
  v_outsider UUID;
  v_product UUID;
  v_enrolment UUID;
  v_replay UUID;
  v_result JSONB;
  v_failed BOOLEAN;
BEGIN
  SELECT organization_id,user_id INTO v_org,v_maker
    FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'SAV01: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('sav-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Savings Checker','farmer')
    RETURNING id INTO v_checker;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(v_org,v_checker,'finance_manager',ARRAY['financial.savings.configure'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES
    ('sav-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','Savings Outsider','farmer')
    RETURNING id INTO v_outsider;

  v_result:=create_savings_product_draft(v_org,v_maker,'SAV.HARVEST','Harvest goal','NGN',10000,50000000,
    'monthly',1000000,90,7,'forfeit_returns',0,'simple_interest',750,'actual_365','2026.1',repeat('a',64),
    jsonb_build_object('minimumKycTier',1),'sav-product-create-001','2026-08-09T10:00:00Z');
  v_product:=(v_result->'product'->>'id')::UUID;
  IF v_product IS NULL OR v_result->'version'->>'disclosure_version'<>'2026.1' THEN
    RAISE EXCEPTION 'SAV01: product draft did not preserve its disclosure';
  END IF;

  PERFORM submit_savings_product(v_org,v_maker,v_product,1,'sav-product-submit-001','2026-08-09T10:01:00Z');
  v_failed:=FALSE;
  BEGIN
    PERFORM approve_savings_product(v_org,v_maker,v_product,1,'sav-product-self-approve-001','2026-08-09T10:02:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Maker cannot approve%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'SAV01: maker approved their own product'; END IF;

  PERFORM approve_savings_product(v_org,v_checker,v_product,1,'sav-product-approve-001','2026-08-09T10:03:00Z');
  IF NOT EXISTS(SELECT 1 FROM savings_products WHERE id=v_product AND organization_id=v_org AND state='active')
    OR NOT EXISTS(SELECT 1 FROM savings_product_versions WHERE product_id=v_product AND state='active' AND approved_by=v_checker)
  THEN RAISE EXCEPTION 'SAV01: independent approval did not activate the product'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM enrol_savings_product(v_org,v_maker,v_product,2000000,'2026.1',repeat('b',64),
      'sav-enrolment-wrong-disclosure','2026-08-09T10:04:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%does not match%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'SAV01: mismatched disclosure was accepted'; END IF;

  v_result:=enrol_savings_product(v_org,v_maker,v_product,2000000,'2026.1',repeat('a',64),
    'sav-enrolment-create-001','2026-08-09T10:05:00Z');
  v_enrolment:=(v_result->>'id')::UUID;
  v_replay:=(enrol_savings_product(v_org,v_maker,v_product,2000000,'2026.1',repeat('a',64),
    'sav-enrolment-create-001','2026-08-09T10:06:00Z')->>'id')::UUID;
  IF v_enrolment IS NULL OR v_replay<>v_enrolment THEN RAISE EXCEPTION 'SAV01: enrolment replay was not idempotent'; END IF;
  IF (SELECT count(*) FROM financial_accounts WHERE organization_id=v_org AND owner_type='savings_contract' AND owner_id=v_enrolment
      AND purpose IN ('savings_principal','savings_accrued_return'))<>2
  THEN RAISE EXCEPTION 'SAV01: canonical savings accounts were not provisioned'; END IF;
  IF NOT EXISTS(SELECT 1 FROM savings_enrolments WHERE id=v_enrolment AND accepted_disclosure_version='2026.1'
      AND accepted_disclosure_hash=repeat('a',64) AND lock_expires_at='2026-11-07T10:05:00Z')
  THEN RAISE EXCEPTION 'SAV01: enrolment evidence or lock date is incorrect'; END IF;

  v_failed:=FALSE;
  BEGIN
    PERFORM list_active_savings_products(v_org,v_outsider);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%not an active organization member%' THEN v_failed:=TRUE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'SAV01: cross-tenant product read was accepted'; END IF;
  IF jsonb_array_length(list_member_savings_enrolments(v_org,v_maker))<>1 THEN
    RAISE EXCEPTION 'SAV01: member enrolment read is incomplete';
  END IF;
  IF (SELECT count(*) FROM organization_audit_log WHERE organization_id=v_org
      AND action IN ('SAVINGS_PRODUCT_DRAFTED','SAVINGS_PRODUCT_SUBMITTED','SAVINGS_PRODUCT_APPROVED','SAVINGS_PRODUCT_ENROLLED'))<>4
  THEN RAISE EXCEPTION 'SAV01: lifecycle audit evidence is incomplete'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO savings_products(organization_id,code,name,currency,created_by,creation_key,creation_hash)
      VALUES(gen_random_uuid(),'SAV.FORGE','Forged product','NGN',gen_random_uuid(),'forged-product-key',repeat('a',64));
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'SAV01: service role directly inserted a savings product'; END IF;
END $$;
RESET ROLE;
