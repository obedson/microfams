BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; period_id UUID; bank UUID; revenue UUID; expense UUID; result JSONB; cutoff TIMESTAMPTZ;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac02-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC02 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac02-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC02 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac02-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC02 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC02 Tenant','ac02-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC02 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open') RETURNING id INTO period_id;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC02.BANK','AC02 bank','asset','debit','NGN','organization',TRUE,owner) RETURNING id INTO bank;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC02.REVENUE','AC02 revenue','revenue','credit','NGN','organization',FALSE,owner) RETURNING id INTO revenue;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC02.EXPENSE','AC02 expense','expense','debit','NGN','organization',FALSE,owner) RETURNING id INTO expense;
 PERFORM post_financial_journal(org,'NGN',DATE '2028-03-01','accounting.income_statement','revenue','ac02-revenue',repeat('a',64),'00000000-0000-4000-8000-000000002401','AC02 revenue',owner,jsonb_build_array(jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',90000),jsonb_build_object('account_id',revenue,'line_number',2,'side','credit','amount_minor',90000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-04-01','accounting.income_statement','expense','ac02-expense',repeat('b',64),'00000000-0000-4000-8000-000000002402','AC02 expense',owner,jsonb_build_array(jsonb_build_object('account_id',expense,'line_number',1,'side','debit','amount_minor',35000),jsonb_build_object('account_id',bank,'line_number',2,'side','credit','amount_minor',35000)));
 cutoff:=clock_timestamp(); result:=read_accounting_income_statement(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff);
 IF result->>'totalRevenueMinor'<>'90000' OR result->>'totalExpenseMinor'<>'35000' OR result->>'netIncomeMinor'<>'55000' OR jsonb_array_length(result->'revenue')<>2 THEN RAISE EXCEPTION 'AC02 income statement totals are invalid: %',result; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'revenue') item WHERE item->>'code'='AC02.REVENUE' AND item->>'amountMinor'='90000') OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'revenue') item WHERE item->>'code'='AC02.EXPENSE' AND item->>'amountMinor'='35000') THEN RAISE EXCEPTION 'AC02 income statement classifications are invalid'; END IF;
 BEGIN PERFORM read_accounting_income_statement(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff); RAISE EXCEPTION 'unauthorized income statement read was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized income statement read was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_INCOME_STATEMENT_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 BEGIN PERFORM read_accounting_income_statement(org,reader,'NGN',DATE '2028-01-01',DATE '2029-01-01',cutoff); RAISE EXCEPTION 'cross-period income statement was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='cross-period income statement was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_INCOME_STATEMENT_PERIOD_REQUIRED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_income_statement(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass income statement boundary'; END IF;
END $$;
SELECT 'accounting income statement schema tests passed' AS result;
ROLLBACK;
