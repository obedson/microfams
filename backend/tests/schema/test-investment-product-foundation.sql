-- INV-01 database contract: governed products, disclosures, replay, maker-checker, and isolation.
SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID; maker UUID; checker UUID; outsider UUID; result JSONB; product UUID; version_id UUID; failed BOOLEAN; facts JSONB;
BEGIN
 SELECT organization_id,user_id INTO org,maker FROM organization_memberships WHERE role='owner' AND status='active' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('inv-checker-'||gen_random_uuid()||'@example.test','test','Investment Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.investments.configure'],'active',NOW());
 INSERT INTO users(email,password,name,role) VALUES('inv-outsider-'||gen_random_uuid()||'@example.test','test','Investment Outsider','farmer') RETURNING id INTO outsider;
 facts:=jsonb_build_object('issuerName','Farm Project Issuer','operatorName','Licensed Investment Operator','underlyingReference','farm-project-inv01','fundingTargetMinor',10000000,'minimumSubscriptionMinor',100000,'maximumSubscriptionMinor',2000000,'offerOpensAt','2026-09-01T00:00:00Z','offerClosesAt','2026-09-30T00:00:00Z','unitMethod','fixed_unit_price','unitPriceMinor',10000,'oversubscriptionPolicy','pro_rata','fees','[]'::JSONB,'expectedReturnDisclosure','Expected returns are estimates and are not guaranteed.','lossAllocationRule',jsonb_build_object('method','pro_rata_units'),'reportingSchedule',jsonb_build_object('frequency','quarterly'),'maturityAt','2027-09-30T00:00:00Z','exitRules',jsonb_build_object('earlyExit',FALSE),'jurisdictionEligibility',jsonb_build_object('countries',jsonb_build_array('NG')),'riskDisclosureVersion','INV-01.1','riskDisclosureHash',repeat('a',64),'conflictsDisclosure','The operator discloses all related-party interests.');
 result:=create_investment_product_draft(org,maker,'INV.FARM.01','Farm expansion units','NGN',facts,'inv01-create-001','2026-08-13T17:30:00Z'); product:=(result->'product'->>'id')::UUID; version_id:=(result->'version'->>'id')::UUID;
 IF product IS NULL OR result->'version'->>'oversubscription_policy'<>'pro_rata' OR result->'version'->>'risk_disclosure_hash'<>repeat('a',64) THEN RAISE EXCEPTION 'INV01: governed snapshot is incomplete'; END IF;
 IF (create_investment_product_draft(org,maker,'INV.FARM.01','Farm expansion units','NGN',facts,'inv01-create-001','2026-08-13T17:30:00Z')->'product'->>'id')::UUID<>product THEN RAISE EXCEPTION 'INV01: creation replay failed'; END IF;
 PERFORM submit_investment_product(org,maker,product,1,'inv01-submit-001','2026-08-13T17:31:00Z');
 failed:=FALSE; BEGIN PERFORM approve_investment_product(org,maker,product,1,'inv01-maker-approve','2026-08-13T17:32:00Z'); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%independent%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV01: maker approved own product'; END IF;
 result:=approve_investment_product(org,checker,product,1,'inv01-approve-001','2026-08-13T17:33:00Z');
 IF result->'product'->>'state'<>'approved' OR result->'version'->>'approved_by'<>checker::TEXT OR NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=org AND action='INVESTMENT_PRODUCT_APPROVED' AND resource_id=product::TEXT) THEN RAISE EXCEPTION 'INV01: approval evidence is incomplete'; END IF;
 failed:=FALSE; BEGIN PERFORM create_investment_product_draft(org,outsider,'INV.BAD.01','Outsider product','NGN',facts,'inv01-outsider-001',NOW()); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Missing financial.investments.configure permission%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV01: outsider configured tenant investment'; END IF;
 IF has_table_privilege('service_role','public.investment_product_versions','UPDATE') THEN RAISE EXCEPTION 'INV01: version evidence is mutable'; END IF;
END $$;
ROLLBACK;
SELECT 'investment product foundation schema tests passed' AS result;
