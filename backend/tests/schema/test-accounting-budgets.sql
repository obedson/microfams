BEGIN;
DO $$
DECLARE owner UUID; reader UUID; denied UUID; org UUID; period UUID; cash UUID; expense UUID; budget UUID; replay UUID; result JSONB; cutoff TIMESTAMPTZ;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('ac05-owner-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC05 Owner','farmer') RETURNING id INTO owner;
 INSERT INTO users(email,password,name,role) VALUES('ac05-reader-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC05 Reader','farmer') RETURNING id INTO reader;
 INSERT INTO users(email,password,name,role) VALUES('ac05-denied-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','AC05 Denied','farmer') RETURNING id INTO denied;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('AC05 Tenant','ac05-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',owner) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,owner,'owner','active',ARRAY['financial.accounting.post'],NOW()),(org,reader,'member','active',ARRAY['financial.accounting.read'],NOW());
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'AC05 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open') RETURNING id INTO period;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by,purpose) VALUES(org,'AC05.CASH','AC05 cash','asset','debit','NGN','organization',TRUE,owner,'operating_cash') RETURNING id INTO cash;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by) VALUES(org,'AC05.EXPENSE','AC05 expense','expense','debit','NGN','organization',FALSE,owner) RETURNING id INTO expense;
 budget:=create_accounting_budget_version(org,owner,period,'operating','AC05 operating','NGN',jsonb_build_array(jsonb_build_object('account_id',expense,'line_number',1,'amount_minor',50000)),'ac05-budget-v1',clock_timestamp());
 replay:=create_accounting_budget_version(org,owner,period,'operating','AC05 operating','NGN',jsonb_build_array(jsonb_build_object('account_id',expense,'line_number',1,'amount_minor',50000)),'ac05-budget-v1',clock_timestamp());
 IF replay<>budget THEN RAISE EXCEPTION 'AC05 idempotent replay failed'; END IF;
 PERFORM post_financial_journal(org,'NGN',DATE '2028-03-01','expense.posting','expense','ac05-expense',repeat('a',64),'00000000-0000-4000-8000-000000005001','AC05 expense',owner,jsonb_build_array(jsonb_build_object('account_id',expense,'line_number',1,'side','debit','amount_minor',12000),jsonb_build_object('account_id',cash,'line_number',2,'side','credit','amount_minor',12000)));
 cutoff:=clock_timestamp(); result:=read_accounting_budget_vs_actual(org,reader,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff);
 IF result->'budgets'->0->>'version'<>'1' OR result->'budgets'->0->'lines'->0->>'budgetMinor'<>'50000' OR result->'budgets'->0->'lines'->0->>'actualMinor'<>'12000' OR result->'budgets'->0->'lines'->0->>'varianceMinor'<>'38000' THEN RAISE EXCEPTION 'AC05 budget report invalid: %',result; END IF;
 BEGIN UPDATE accounting_budget_versions SET total_minor=1 WHERE id=budget; RAISE EXCEPTION 'budget mutation accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='budget mutation accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_BUDGET_IMMUTABLE%' THEN RAISE; END IF; END;
 BEGIN PERFORM read_accounting_budget_vs_actual(org,denied,'NGN',DATE '2028-01-01',DATE '2028-12-31',cutoff); RAISE EXCEPTION 'unauthorized budget read accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized budget read accepted' OR SQLERRM NOT LIKE '%ACCOUNTING_BUDGET_READ_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','create_accounting_budget_version(uuid,uuid,uuid,text,text,text,jsonb,text,timestamp with time zone)','EXECUTE') OR has_function_privilege('authenticated','read_accounting_budget_vs_actual(uuid,uuid,text,date,date,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass budget boundary'; END IF;
END $$;
SELECT 'accounting budgets schema tests passed' AS result;
ROLLBACK;
