BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; cash UUID; equity UUID; result JSONB;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac07-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC07 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac07-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC07 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac07-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC07 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC07 Tenant','ac07-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC07 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open');
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC07.CASH','AC07 cash','asset','debit','NGN','organization',TRUE,owner) RETURNING id INTO cash;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC07.EQUITY','AC07 equity','equity','credit','NGN','organization',FALSE,owner) RETURNING id INTO equity;
 PERFORM post_financial_journal(org,'NGN',DATE '2028-02-01','audit.test','opening','ac07-entry',repeat('a',64),'00000000-0000-4000-8000-000000007001','AC07 entry',owner,jsonb_build_array(jsonb_build_object('account_id',cash,'line_number',1,'side','debit','amount_minor',1000),jsonb_build_object('account_id',equity,'line_number',2,'side','credit','amount_minor',1000)));
 result:=read_accounting_audit_export(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',clock_timestamp());
 IF result->>'entryCount'<>'1' OR result->>'lineCount'<>'2' OR result->'entries'->0->>'sourceDomain'<>'audit.test' OR jsonb_array_length(result->'entries'->0->'lines')<>2 THEN RAISE EXCEPTION 'AC07 export invalid: %',result; END IF;
 BEGIN PERFORM read_accounting_audit_export(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',clock_timestamp()); RAISE EXCEPTION 'unauthorized audit export accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized audit export accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_AUDIT_EXPORT_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_audit_export(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass audit export boundary'; END IF;
END $$;
SELECT 'accounting audit export schema tests passed' AS result;
ROLLBACK;
