SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101'; owner UUID:=org; payer UUID; beneficiary UUID; checker UUID; wallet UUID; contract UUID; request_id UUID; result JSONB; failed BOOLEAN:=FALSE; now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc07-beneficiary-'||gen_random_uuid()||'@example.test','test','ESC07 Beneficiary','farmer') RETURNING id INTO beneficiary;
 INSERT INTO users(email,password,name,role) VALUES('esc07-checker-'||gen_random_uuid()||'@example.test','test','ESC07 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','first'),jsonb_build_object('name','second'),jsonb_build_object('name','third')),jsonb_build_object('mode','milestone'),jsonb_build_array(to_jsonb(checker::TEXT)),now_at+INTERVAL'7 days',now_at+INTERVAL'14 days','esc07-create-001',now_at); contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc07-activate-001',now_at); PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc07-credit-001'); PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc07-funding-001','00000000-0000-4000-0000-000000000907',now_at);
 result:=request_escrow_release(org,beneficiary,contract,0,30000,jsonb_build_object('evidence','first'),'esc07-request-001',now_at); request_id:=(result->>'id')::UUID; PERFORM decide_escrow_release(org,checker,request_id,'approve','First milestone verified','esc07-approve-001',now_at); PERFORM execute_escrow_release(org,checker,request_id,'00000000-0000-4000-0000-000000000908',now_at);
 result:=request_escrow_release(org,beneficiary,contract,1,20000,jsonb_build_object('evidence','second'),'esc07-request-002',now_at); request_id:=(result->>'id')::UUID; PERFORM decide_escrow_release(org,checker,request_id,'approve','Second milestone verified','esc07-approve-002',now_at); PERFORM execute_escrow_release(org,checker,request_id,'00000000-0000-4000-0000-000000000909',now_at);
 BEGIN PERFORM request_escrow_release(org,beneficiary,contract,2,1,jsonb_build_object('evidence','excess'),'esc07-request-003',now_at); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed OR (SELECT released_minor FROM escrow_contracts WHERE id=contract)<>50000 OR (SELECT state FROM escrow_contracts WHERE id=contract)<>'released' THEN RAISE EXCEPTION 'ESC07: partial release invariant failed'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow partial release schema tests passed' AS result;
