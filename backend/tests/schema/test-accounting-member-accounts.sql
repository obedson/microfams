BEGIN;
DO $$
DECLARE owner UUID; member UUID; reader UUID; denied UUID; org UUID; wallet UUID; clearing UUID; result JSONB; cutoff TIMESTAMPTZ;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac06-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC06 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac06-member-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC06 Member','farmer') RETURNING id INTO member;
 INSERT INTO users(email,password,name,role) VALUES('ac06-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC06 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac06-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC06 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC06 Tenant','ac06-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW()),(org,member,'member','active','{}',NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW()),(org,denied,'member','active','{}',NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC06 FY 2027',DATE '2027-01-01',DATE '2027-12-31','open');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC06 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open');
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES(org,'AC06.WALLET','AC06 wallet','liability','credit','NGN','user',member,TRUE,owner,'individual_wallet_funds') RETURNING id INTO wallet;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC06.CLEAR','AC06 clearing','asset','debit','NGN','system',TRUE,owner) RETURNING id INTO clearing;
 PERFORM post_financial_journal(org,'NGN',DATE '2027-12-31','statement.test','opening','ac06-opening',repeat('a',64),'00000000-0000-4000-8000-000000006001','AC06 opening',owner,jsonb_build_array(jsonb_build_object('account_id',clearing,'line_number',1,'side','debit','amount_minor',10000),jsonb_build_object('account_id',wallet,'line_number',2,'side','credit','amount_minor',10000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-02-01','statement.test','credit','ac06-credit',repeat('b',64),'00000000-0000-4000-8000-000000006002','AC06 credit',owner,jsonb_build_array(jsonb_build_object('account_id',clearing,'line_number',1,'side','debit','amount_minor',2500),jsonb_build_object('account_id',wallet,'line_number',2,'side','credit','amount_minor',2500)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-03-01','statement.test','debit','ac06-debit',repeat('c',64),'00000000-0000-4000-8000-000000006003','AC06 debit',owner,jsonb_build_array(jsonb_build_object('account_id',wallet,'line_number',1,'side','debit','amount_minor',1000),jsonb_build_object('account_id',clearing,'line_number',2,'side','credit','amount_minor',1000)));
 cutoff:=clock_timestamp(); result:=read_accounting_member_statement(org,member,member,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff,1,1);
 IF result->>'openingBalanceMinor'<>'10000' OR result->>'pageOpeningBalanceMinor'<>'12500' OR result->>'closingBalanceMinor'<>'11500' OR result->>'total'<>'2' OR result->'lines'->0->>'description'<>'AC06 debit' THEN RAISE EXCEPTION 'AC06 statement invalid: %',result; END IF;
 PERFORM read_accounting_member_statement(org,reader,member,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff,0,25);
 BEGIN PERFORM read_accounting_member_statement(org,denied,member,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff,0,25); RAISE EXCEPTION 'unauthorized statement accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized statement accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_MEMBER_STATEMENT_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_member_statement(uuid,uuid,uuid,text,date,date,timestamp with time zone,integer,integer)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass member statement boundary'; END IF;
END $$;
SELECT 'accounting member account schema tests passed' AS result;
ROLLBACK;
