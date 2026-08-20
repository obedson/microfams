BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; cash UUID; equity UUID; revenue UUID; investment UUID; loan UUID; result JSONB; cutoff TIMESTAMPTZ;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac04-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC04 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac04-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC04 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac04-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC04 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC04 Tenant','ac04-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active','{}',NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC04 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open');
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by,purpose) VALUES(org,'AC04.CASH','AC04 cash','asset','debit','NGN','organization',TRUE,owner,'operating_cash') RETURNING id INTO cash;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC04.EQUITY','AC04 equity','equity','credit','NGN','organization',FALSE,owner) RETURNING id INTO equity;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC04.REVENUE','AC04 revenue','revenue','credit','NGN','organization',FALSE,owner) RETURNING id INTO revenue;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC04.INV','AC04 investment','asset','debit','NGN','organization',FALSE,owner) RETURNING id INTO investment;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC04.LOAN','AC04 loan','liability','credit','NGN','organization',FALSE,owner) RETURNING id INTO loan;
 PERFORM post_financial_journal(org,'NGN',DATE '2028-02-01','booking.settlement','revenue','ac04-operating',repeat('b',64),'00000000-0000-4000-8000-000000004002','AC04 operating',owner,jsonb_build_array(jsonb_build_object('account_id',cash,'line_number',1,'side','debit','amount_minor',25000),jsonb_build_object('account_id',revenue,'line_number',2,'side','credit','amount_minor',25000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-03-01','investment.subscription','investment','ac04-investing',repeat('c',64),'00000000-0000-4000-8000-000000004003','AC04 investing',owner,jsonb_build_array(jsonb_build_object('account_id',investment,'line_number',1,'side','debit','amount_minor',10000),jsonb_build_object('account_id',cash,'line_number',2,'side','credit','amount_minor',10000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-04-01','loan.disbursement','loan','ac04-financing',repeat('d',64),'00000000-0000-4000-8000-000000004004','AC04 financing',owner,jsonb_build_array(jsonb_build_object('account_id',cash,'line_number',1,'side','debit','amount_minor',7000),jsonb_build_object('account_id',loan,'line_number',2,'side','credit','amount_minor',7000)));
 PERFORM post_financial_journal(org,'NGN',DATE '2028-05-01','misc.adjustment','unknown','ac04-unknown',repeat('e',64),'00000000-0000-4000-8000-000000004005','AC04 unknown',owner,jsonb_build_array(jsonb_build_object('account_id',cash,'line_number',1,'side','debit','amount_minor',3000),jsonb_build_object('account_id',equity,'line_number',2,'side','credit','amount_minor',3000)));
 cutoff:=clock_timestamp(); result:=read_accounting_cash_flow(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff);
 IF result->>'operatingCashFlowMinor'<>'25000' OR result->>'investingCashFlowMinor'<>'-10000' OR result->>'financingCashFlowMinor'<>'7000' OR result->>'unclassifiedCashFlowMinor'<>'3000' OR result->>'netChangeInCashMinor'<>'25000' THEN RAISE EXCEPTION 'AC04 cash flow totals invalid: %',result; END IF;
 IF jsonb_array_length(result->'movements')<>4 THEN RAISE EXCEPTION 'AC04 movement scope invalid'; END IF;
 BEGIN PERFORM read_accounting_cash_flow(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff); RAISE EXCEPTION 'unauthorized cash flow read was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized cash flow read was accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_CASH_FLOW_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','read_accounting_cash_flow(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass cash flow boundary'; END IF;
END $$;
SELECT 'accounting cash flow schema tests passed' AS result;
ROLLBACK;
