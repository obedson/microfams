-- INV-03 database contract: approved offers must be explicitly and idempotently opened.
SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID; maker UUID; checker UUID; outsider UUID; product UUID; result JSONB; facts JSONB; failed BOOLEAN;
BEGIN
 SELECT organization_id,user_id INTO org,maker FROM organization_memberships WHERE role='owner' AND status='active' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('inv03-checker-'||gen_random_uuid()||'@example.test','test','INV-03 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.investments.configure'],'active',NOW());
 INSERT INTO users(email,password,name,role) VALUES('inv03-outsider-'||gen_random_uuid()||'@example.test','test','INV-03 Outsider','farmer') RETURNING id INTO outsider;
 facts:=jsonb_build_object('issuerName','Farm Project Issuer','operatorName','Licensed Investment Operator','underlyingReference','farm-project-inv03','fundingTargetMinor',10000000,'minimumSubscriptionMinor',100000,'maximumSubscriptionMinor',2000000,'offerOpensAt','2026-09-01T00:00:00Z','offerClosesAt','2026-09-30T00:00:00Z','unitMethod','fixed_unit_price','unitPriceMinor',10000,'oversubscriptionPolicy','pro_rata','fees','[]'::JSONB,'expectedReturnDisclosure','Expected returns are estimates and are not guaranteed.','lossAllocationRule',jsonb_build_object('method','pro_rata_units'),'reportingSchedule',jsonb_build_object('frequency','quarterly'),'maturityAt','2027-09-30T00:00:00Z','exitRules',jsonb_build_object('earlyExit',FALSE),'jurisdictionEligibility',jsonb_build_object('countries',jsonb_build_array('NG'),'investorTypes',jsonb_build_array('individual')),'riskDisclosureVersion','INV-03.1','riskDisclosureHash',repeat('c',64),'conflictsDisclosure','The operator discloses all related-party interests.');
 result:=create_investment_product_draft(org,maker,'INV.FARM.03','INV-03 farm units','NGN',facts,'inv03-product-create','2026-08-13T19:00:00Z'); product:=(result->'product'->>'id')::UUID;
 PERFORM submit_investment_product(org,maker,product,1,'inv03-product-submit','2026-08-13T19:01:00Z'); PERFORM approve_investment_product(org,checker,product,1,'inv03-product-approve','2026-08-13T19:02:00Z');
 failed:=FALSE; BEGIN PERFORM create_investment_subscription_intent(org,maker,product,500000,'NG','individual','INV-03.1',repeat('c',64),'00000000-0000-4000-8000-000000000301','inv03-before-open','2026-09-15T12:00:00Z'); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not available%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV03: approved but unopened product accepted subscription'; END IF;
 failed:=FALSE; BEGIN PERFORM open_investment_product_offer(org,checker,product,1,'inv03-open-early','2026-08-31T23:59:59Z'); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%outside its approved window%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV03: offer opened outside approved window'; END IF;
 failed:=FALSE; BEGIN PERFORM open_investment_product_offer(org,outsider,product,1,'inv03-open-outsider','2026-09-15T11:59:00Z'); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Missing financial.investments.configure permission%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV03: outsider opened tenant offer'; END IF;
 result:=open_investment_product_offer(org,checker,product,1,'inv03-open-001','2026-09-15T11:59:00Z');
 IF result->'product'->>'state'<>'open' OR NOT EXISTS(SELECT 1 FROM investment_product_events WHERE product_id=product AND action='opened') OR NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=org AND action='INVESTMENT_OFFER_OPENED' AND resource_id=product::TEXT) THEN RAISE EXCEPTION 'INV03: opening evidence is incomplete'; END IF;
 IF (open_investment_product_offer(org,checker,product,1,'inv03-open-001','2026-09-15T12:05:00Z')->'product'->>'id')::UUID<>product THEN RAISE EXCEPTION 'INV03: opening replay failed'; END IF;
 result:=create_investment_subscription_intent(org,maker,product,500000,'NG','individual','INV-03.1',repeat('c',64),'00000000-0000-4000-8000-000000000302','inv03-after-open','2026-09-15T12:00:00Z');
 IF result->'subscription'->>'state'<>'pending' THEN RAISE EXCEPTION 'INV03: open offer did not accept pending intent'; END IF;
END $$;
ROLLBACK;
SELECT 'investment offer opening schema tests passed' AS result;
