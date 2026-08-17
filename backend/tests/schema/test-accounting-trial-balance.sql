BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; other_org UUID; period_id UUID; bank UUID; equity UUID; revenue UUID; expense UUID; liability UUID; cutoff TIMESTAMPTZ; result JSONB;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac01-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC01 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac01-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC01 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac01-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC01 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC01 Tenant','ac01-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC01 Other','ac01-other-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',denied) RETURNING id INTO other_org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW());
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW());
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(other_org,denied,'owner','active','{}',NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC01 FY 2027',DATE '2027-01-01',DATE '2027-12-31','open');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC01 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open') RETURNING id INTO period_id;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (org,'AC01.BANK','AC01 operating bank','asset','debit','NGN','organization',TRUE,owner) RETURNING id INTO bank;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (org,'AC01.EQUITY','AC01 opening equity','equity','credit','NGN','organization',FALSE,owner) RETURNING id INTO equity;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (org,'AC01.REVENUE','AC01 revenue','revenue','credit','NGN','organization',FALSE,owner) RETURNING id INTO revenue;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (org,'AC01.EXPENSE','AC01 expense','expense','debit','NGN','organization',FALSE,owner) RETURNING id INTO expense;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (org,'AC01.LIABILITY','AC01 unused liability','liability','credit','NGN','organization',FALSE,owner) RETURNING id INTO liability;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES
  (other_org,'AC01.BANK','Other tenant bank','asset','debit','NGN','organization',TRUE,denied);
 PERFORM post_financial_journal(org,'NGN',DATE '2027-12-31','accounting.trial_balance','opening','ac01-opening',repeat('a',64),'00000000-0000-4000-8000-000000002301','AC01 opening balances',owner,jsonb_build_array(
  jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',100000),jsonb_build_object('account_id',equity,'line_number',2,'side','credit','amount_minor',100000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-04-10','accounting.trial_balance','expense','ac01-expense',repeat('b',64),'00000000-0000-4000-8000-000000002302','AC01 operating expense',owner,jsonb_build_array(
  jsonb_build_object('account_id',expense,'line_number',1,'side','debit','amount_minor',25000),jsonb_build_object('account_id',bank,'line_number',2,'side','credit','amount_minor',25000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-06-15','accounting.trial_balance','revenue','ac01-revenue',repeat('c',64),'00000000-0000-4000-8000-000000002303','AC01 earned revenue',owner,jsonb_build_array(
  jsonb_build_object('account_id',bank,'line_number',1,'side','debit','amount_minor',40000),jsonb_build_object('account_id',revenue,'line_number',2,'side','credit','amount_minor',40000)));
 UPDATE accounting_periods SET status='closed',closed_at=clock_timestamp(),closed_by=owner WHERE id=period_id;
 cutoff:=clock_timestamp();
 result:=read_accounting_trial_balance(org,reader,'ngn',DATE '2028-01-01',DATE '2028-12-31',cutoff);
 IF result->>'organizationId'<>org::TEXT OR result->>'currency'<>'NGN' OR result->'period'->>'status'<>'closed' OR jsonb_array_length(result->'accounts')<>5 THEN RAISE EXCEPTION 'AC01 trial balance scope is invalid: %',result; END IF;
 IF result->'totals'->>'periodDebitMinor'<>'65000' OR result->'totals'->>'periodCreditMinor'<>'65000' OR result->'totals'->>'closingDebitMinor'<>'140000' OR result->'totals'->>'closingCreditMinor'<>'140000' THEN RAISE EXCEPTION 'AC01 trial balance totals are invalid: %',result; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'accounts') account WHERE account->>'code'='AC01.BANK' AND account->>'openingDebitMinor'='100000' AND account->>'periodDebitMinor'='40000' AND account->>'periodCreditMinor'='25000' AND account->>'closingDebitMinor'='115000') THEN RAISE EXCEPTION 'AC01 bank balance is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'accounts') account WHERE account->>'code'='AC01.EXPENSE' AND account->>'closingDebitMinor'='25000') OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'accounts') account WHERE account->>'code'='AC01.REVENUE' AND account->>'closingCreditMinor'='40000') OR EXISTS(SELECT 1 FROM jsonb_array_elements(result->'accounts') account WHERE account->>'name'='Other tenant bank') THEN RAISE EXCEPTION 'AC01 account balances are not tenant isolated'; END IF;
 BEGIN PERFORM read_accounting_trial_balance(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff); RAISE EXCEPTION 'unauthorized trial balance read was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized trial balance read was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_TRIAL_BALANCE_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 BEGIN PERFORM read_accounting_trial_balance(org,reader,'NGN',DATE '2028-01-01',DATE '2029-01-01',cutoff); RAISE EXCEPTION 'cross-period trial balance was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='cross-period trial balance was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_TRIAL_BALANCE_PERIOD_REQUIRED%' THEN RAISE; END IF; END;
 BEGIN PERFORM read_accounting_trial_balance(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',clock_timestamp()+INTERVAL '1 hour'); RAISE EXCEPTION 'future-cutoff trial balance was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='future-cutoff trial balance was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_TRIAL_BALANCE_REQUEST_INVALID%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_trial_balance(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass the accounting read boundary'; END IF;
END $$;
SELECT 'accounting trial balance schema tests passed' AS result;
ROLLBACK;
