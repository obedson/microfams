BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; other_org UUID; bank UUID; liability UUID; equity UUID; revenue UUID; expense UUID; result JSONB; cutoff TIMESTAMPTZ;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac03-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC03 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac03-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC03 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac03-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC03 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC03 Tenant','ac03-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC03 Other','ac03-other-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',denied) RETURNING id INTO other_org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW()),(other_org,denied,'owner','active','{}',NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC03 FY 2027',DATE '2027-01-01',DATE '2027-12-31','open'); INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC03 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open');
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC03.BANK','AC03 bank','asset','debit','NGN','organization',TRUE,owner) RETURNING id INTO bank;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC03.LIABILITY','AC03 payable','liability','credit','NGN','organization',FALSE,owner) RETURNING id INTO liability;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC03.EQUITY','AC03 equity','equity','credit','NGN','organization',FALSE,owner) RETURNING id INTO equity;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC03.REVENUE','AC03 revenue','revenue','credit','NGN','organization',FALSE,owner) RETURNING id INTO revenue;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (org,'AC03.EXPENSE','AC03 expense','expense','debit','NGN','organization',FALSE,owner) RETURNING id INTO expense;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
 (other_org,'AC03.BANK','Other tenant bank','asset','debit','NGN','organization',TRUE,denied);
 PERFORM post_financial_journal(org,'NGN',DATE '2027-12-31','accounting.balance_sheet','opening','ac03-opening',repeat('a',64),'00000000-0000-4000-8000-000000002501','AC03 opening',owner,jsonb_build_array(jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',100000),jsonb_build_object('account_id',equity,'line_number',2,'side','credit','amount_minor',100000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-04-01','accounting.balance_sheet','revenue','ac03-revenue',repeat('b',64),'00000000-0000-4000-8000-000000002502','AC03 revenue',owner,jsonb_build_array(jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',40000),jsonb_build_object('account_id',revenue,'line_number',2,'side','credit','amount_minor',40000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-05-01','accounting.balance_sheet','expense','ac03-expense',repeat('c',64),'00000000-0000-4000-8000-000000002503','AC03 expense',owner,jsonb_build_array(jsonb_build_object('account_id',expense,'line_number',1,'side','debit','amount_minor',15000),jsonb_build_object('account_id',bank,'line_number',2,'side','credit','amount_minor',15000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-06-01','accounting.balance_sheet','liability','ac03-liability',repeat('d',64),'00000000-0000-4000-8000-000000002504','AC03 payable',owner,jsonb_build_array(jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',10000),jsonb_build_object('account_id',liability,'line_number',2,'side','credit','amount_minor',10000)));
 cutoff:=clock_timestamp(); result:=read_accounting_balance_sheet(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff);
 IF result->>'totalAssetsMinor'<>'135000' OR result->>'totalLiabilitiesMinor'<>'10000' OR result->>'totalEquityMinor'<>'100000' OR result->>'currentPeriodNetIncomeMinor'<>'25000' OR result->>'totalLiabilitiesAndEquityMinor'<>'135000' THEN RAISE EXCEPTION 'AC03 balance sheet totals invalid: %',result; END IF;
 IF jsonb_array_length(result->'accounts')<>3 OR EXISTS(SELECT 1 FROM jsonb_array_elements(result->'accounts') item WHERE item->>'name'='Other tenant bank') THEN RAISE EXCEPTION 'AC03 account scope invalid'; END IF;
 BEGIN PERFORM read_accounting_balance_sheet(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff); RAISE EXCEPTION 'unauthorized balance sheet read was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized balance sheet read was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_BALANCE_SHEET_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 BEGIN PERFORM read_accounting_balance_sheet(org,reader,'NGN',DATE '2028-01-01',DATE '2029-01-01',cutoff); RAISE EXCEPTION 'cross-period balance sheet was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='cross-period balance sheet was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_BALANCE_SHEET_PERIOD_REQUIRED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_balance_sheet(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass balance sheet boundary'; END IF;
END $$;
SELECT 'accounting balance sheet schema tests passed' AS result;
ROLLBACK;
