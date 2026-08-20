BEGIN;
DO $$
DECLARE creator UUID; reviewer UUID; approver UUID; member UUID; org UUID; period UUID; distribution UUID; row dividend_distributions;
BEGIN
 INSERT INTO users(email,password,name,role) VALUES('div02-create-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV02 Creator','farmer') RETURNING id INTO creator;
 INSERT INTO users(email,password,name,role) VALUES('div02-review-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV02 Reviewer','farmer') RETURNING id INTO reviewer;
 INSERT INTO users(email,password,name,role) VALUES('div02-approve-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV02 Approver','farmer') RETURNING id INTO approver;
 INSERT INTO users(email,password,name,role) VALUES('div02-member-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','DIV02 Member','farmer') RETURNING id INTO member;
 INSERT INTO organizations(name,slug,type,created_by) VALUES('DIV02 Tenant','div02-'||replace(gen_random_uuid()::TEXT,'-',''),'cooperative',creator) RETURNING id INTO org;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,creator,'member','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,reviewer,'member','active',ARRAY['financial.accounting.post'],DATE '2027-01-01'),(org,approver,'member','active',ARRAY['financial.rules.approve'],DATE '2027-01-01'),(org,member,'member','active','{}',DATE '2027-01-01');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'DIV02 FY 2027',DATE '2027-01-01',DATE '2027-12-31','closed') RETURNING id INTO period;
 distribution:=calculate_dividend_entitlement_snapshot(org,creator,period,'fy2027_surplus','NGN',1000,100,DATE '2027-12-31',DATE '2028-02-01','{}',jsonb_build_array(jsonb_build_object('member_id',member,'paid_units',1)),'div02-calc',clock_timestamp());
 BEGIN PERFORM review_dividend_distribution(org,creator,distribution,'Creator cannot self review',clock_timestamp()); RAISE EXCEPTION 'self review accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='self review accepted' OR SQLERRM NOT LIKE '%DIVIDEND_REVIEW_STATE_INVALID%' THEN RAISE; END IF; END;
 PERFORM review_dividend_distribution(org,reviewer,distribution,'Eligibility and allocation independently reviewed',clock_timestamp());
 BEGIN PERFORM approve_dividend_distribution(org,reviewer,distribution,clock_timestamp()); RAISE EXCEPTION 'reviewer self approval accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='reviewer self approval accepted' OR SQLERRM NOT LIKE '%DIVIDEND_APPROVAL_PERMISSION_DENIED%' AND SQLERRM NOT LIKE '%DIVIDEND_APPROVAL_STATE_INVALID%' THEN RAISE; END IF; END;
 PERFORM approve_dividend_distribution(org,approver,distribution,clock_timestamp());
 SELECT * INTO row FROM dividend_distributions WHERE id=distribution;
 IF row.state<>'approved' OR row.reviewed_by<>reviewer OR row.approved_by<>approver OR (SELECT count(*) FROM dividend_distribution_events WHERE distribution_id=distribution)<>2 THEN RAISE EXCEPTION 'DIV02 approval evidence invalid'; END IF;
 BEGIN UPDATE dividend_distributions SET state='payable' WHERE id=distribution; RAISE EXCEPTION 'direct transition accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='direct transition accepted' OR SQLERRM NOT LIKE '%DIVIDEND_SNAPSHOT_IMMUTABLE%' THEN RAISE; END IF; END;
 IF has_function_privilege('authenticated','review_dividend_distribution(uuid,uuid,uuid,text,timestamp with time zone)','EXECUTE') OR has_function_privilege('authenticated','approve_dividend_distribution(uuid,uuid,uuid,timestamp with time zone)','EXECUTE') THEN RAISE EXCEPTION 'authenticated clients can bypass dividend approval boundary'; END IF;
END $$;
SELECT 'dividend review and approval schema tests passed' AS result;
ROLLBACK;
