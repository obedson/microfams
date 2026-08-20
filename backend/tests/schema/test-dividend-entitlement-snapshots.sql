BEGIN;
DO $$
DECLARE owner UUID; member_a UUID; member_b UUID; denied UUID; org UUID; period UUID; distribution UUID; replay UUID; row dividend_distributions;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('div01-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV01 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('div01-a-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV01 A','farmer') RETURNING id INTO member_a;
 INSERT INTO users(email,password,name,role) VALUES('div01-b-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV01 B','farmer') RETURNING id INTO member_b;
 INSERT INTO users(email,password,name,role) VALUES('div01-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV01 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('DIV01 Tenant','div01-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,member_a,'member','active','{}',DATE '2027-01-01'),(org,member_b,'member','active','{}',DATE '2027-01-01'),(org,denied,'member','active','{}',DATE '2027-01-01');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'DIV01 FY 2027',DATE '2027-01-01',DATE '2027-12-31','closed') RETURNING id INTO period;
 distribution:=calculate_dividend_entitlement_snapshot(org,owner,period,'fy2027_surplus','NGN',10001,5000,DATE '2027-12-31',DATE '2028-02-01',jsonb_build_object('rule','none'),jsonb_build_array(jsonb_build_object('member_id',member_a,'paid_units',1),jsonb_build_object('member_id',member_b,'paid_units',2)),'div01-calc-v1',clock_timestamp());
 replay:=calculate_dividend_entitlement_snapshot(org,owner,period,'fy2027_surplus','NGN',10001,5000,DATE '2027-12-31',DATE '2028-02-01',jsonb_build_object('rule','none'),jsonb_build_array(jsonb_build_object('member_id',member_a,'paid_units',1),jsonb_build_object('member_id',member_b,'paid_units',2)),'div01-calc-v1',clock_timestamp());
 IF replay<>distribution THEN RAISE EXCEPTION 'DIV01 idempotent replay failed'; END IF;
 SELECT * INTO row FROM dividend_distributions WHERE id=distribution;
 IF row.state<>'calculated' OR row.eligible_units<>3 OR row.allocated_minor<>10000 OR row.rounding_residual_minor<>1 OR (SELECT sum(gross_minor) FROM dividend_entitlements WHERE distribution_id=distribution)<>10000 THEN RAISE EXCEPTION 'DIV01 allocation invalid'; END IF;
 BEGIN UPDATE dividend_entitlements SET gross_minor=0 WHERE distribution_id=distribution; RAISE EXCEPTION 'entitlement mutation accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='entitlement mutation accepted' OR SQLERRM NOT LIKE '%DIVIDEND_SNAPSHOT_IMMUTABLE%' THEN RAISE; END IF; END;
 BEGIN PERFORM calculate_dividend_entitlement_snapshot(org,denied,period,'denied','NGN',1000,0,DATE '2027-12-31',DATE '2028-02-01','{}',jsonb_build_array(jsonb_build_object('member_id',member_a,'paid_units',1)),'div01-denied',clock_timestamp()); RAISE EXCEPTION 'unauthorized dividend calculation accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized dividend calculation accepted' OR SQLERRM NOT LIKE '%DIVIDEND_CALCULATION_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','calculate_dividend_entitlement_snapshot(uuid,uuid,uuid,text,text,bigint,bigint,date,date,jsonb,jsonb,text,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass dividend boundary'; END IF;
END $$;
SELECT 'dividend entitlement snapshot schema tests passed' AS result;
ROLLBACK;
