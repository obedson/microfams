BEGIN;
DO $$
DECLARE creator UUID; reviewer UUID; approver UUID; accountant UUID; member UUID; org UUID; source_period UUID; retained UUID; payable UUID; distribution UUID; journal UUID; replay UUID; row dividend_distributions;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('div03-create-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV03 Creator','farmer') RETURNING id INTO creator;
 INSERT INTO users(email,password,name,role) VALUES('div03-review-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV03 Reviewer','farmer') RETURNING id INTO reviewer;
 INSERT INTO users(email,password,name,role) VALUES('div03-approve-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV03 Approver','farmer') RETURNING id INTO approver;
 INSERT INTO users(email,password,name,role) VALUES('div03-account-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV03 Accountant','farmer') RETURNING id INTO accountant;
 INSERT INTO users(email,password,name,role) VALUES('div03-member-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV03 Member','farmer') RETURNING id INTO member;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('DIV03 Tenant','div03-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',creator) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,creator,'member','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,reviewer,'member','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,approver,'member','active',ARRAY['financial.rules.approve'],DATE '2027-01-01'),(org,accountant,'member','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,member,'member','active','{}',DATE '2027-01-01');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'DIV03 FY 2027',DATE '2027-01-01',DATE '2027-12-31','closed') RETURNING id INTO source_period;
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'DIV03 FY 2028',DATE '2028-01-01',DATE '2028-12-31','open');
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by,purpose) VALUES(org,'DIV03.RETAINED','DIV03 retained surplus','equity','credit','NGN','organization',TRUE,creator,'retained_surplus') RETURNING id INTO retained;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control,created_by,purpose) VALUES(org,'DIV03.PAYABLE','DIV03 dividends payable','liability','credit','NGN','organization',TRUE,creator,'dividends_payable') RETURNING id INTO payable;
 distribution:=calculate_dividend_entitlement_snapshot(org,creator,source_period,'fy2027_surplus','NGN',1001,100,DATE '2027-12-31',DATE '2028-02-01','{}',jsonb_build_array(jsonb_build_object('member_id',member,'paid_units',1)),'div03-calc',clock_timestamp());
 PERFORM review_dividend_distribution(org,reviewer,distribution,'Distribution independently reviewed',clock_timestamp()); PERFORM approve_dividend_distribution(org,approver,distribution,clock_timestamp());
 journal:=recognize_dividend_payable(org,accountant,distribution,retained,payable,DATE '2028-02-01','div03-payable','00000000-0000-4000-8000-000000006301',clock_timestamp());
 replay:=recognize_dividend_payable(org,accountant,distribution,retained,payable,DATE '2028-02-01','div03-payable','00000000-0000-4000-8000-000000006301',clock_timestamp());
 SELECT * INTO row FROM dividend_distributions WHERE id=distribution;
 IF replay<>journal OR row.state<>'payable' OR row.payable_journal_entry_id<>journal OR (SELECT count(*) FROM journal_lines WHERE journal_entry_id=journal)<>2 OR (SELECT sum(amount_minor) FROM journal_lines WHERE journal_entry_id=journal AND side='debit')<>1001 OR (SELECT sum(amount_minor) FROM journal_lines WHERE journal_entry_id=journal AND side='credit')<>1001 THEN RAISE EXCEPTION 'DIV03 payable recognition invalid'; END IF;
 BEGIN PERFORM recognize_dividend_payable(org,member,distribution,retained,payable,DATE '2028-02-01','div03-denied','00000000-0000-4000-8000-000000006302',clock_timestamp()); RAISE EXCEPTION 'unauthorized payable recognition accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized payable recognition accepted' OR SQLERRM NOT LIKE '%DIVIDEND_PAYABLE_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','recognize_dividend_payable(uuid,uuid,uuid,uuid,uuid,date,text,uuid,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass dividend payable boundary'; END IF;
END $$;
SELECT 'dividend payable recognition schema tests passed' AS result;
ROLLBACK;
