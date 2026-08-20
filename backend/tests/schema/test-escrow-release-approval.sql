SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101';owner UUID:=org;payer UUID;beneficiary UUID;checker UUID;arbiter UUID;wallet UUID;contract UUID;request_id UUID;result JSONB;replay UUID;failed BOOLEAN;now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 INSERT INTO users(email,password,name,role)VALUES('esc04-b-'||gen_random_uuid()||'@example.test','test','ESC04 Beneficiary','farmer')RETURNING id INTO beneficiary;
 INSERT INTO users(email,password,name,role)VALUES('esc04-c-'||gen_random_uuid()||'@example.test','test','ESC04 Checker','farmer')RETURNING id INTO checker;
 INSERT INTO users(email,password,name,role)VALUES('esc04-a-'||gen_random_uuid()||'@example.test','test','ESC04 Arbiter','farmer')RETURNING id INTO arbiter;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at),(org,arbiter,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(to_jsonb(arbiter::TEXT)),now_at+INTERVAL'7 days',now_at+INTERVAL'14 days','esc04-create-001',now_at);contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc04-activate-001',now_at);PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc04-credit-001');PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc04-funding-001','00000000-0000-4000-8000-000000000904',now_at);
 result:=request_escrow_release(org,beneficiary,contract,0,30000,jsonb_build_object('delivery_note','sha256:def'),'esc04-request-001',now_at);request_id:=(result->>'id')::UUID;
 failed:=FALSE;BEGIN PERFORM decide_escrow_release(org,beneficiary,request_id,'approve','Self approval','esc04-self-001',now_at);EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE'%independent%'THEN failed:=TRUE;END IF;END;IF NOT failed THEN RAISE EXCEPTION'ESC04: requester self-approved';END IF;
 result:=decide_escrow_release(org,arbiter,request_id,'approve','Evidence verified','esc04-approve-001',now_at);replay:=(decide_escrow_release(org,arbiter,request_id,'approve','Evidence verified','esc04-approve-001',now_at+INTERVAL'1 second')->>'id')::UUID;
 IF result->>'state'<>'approved' OR replay<>request_id OR result->>'decided_by'<>arbiter::TEXT THEN RAISE EXCEPTION'ESC04: approval or replay failed';END IF;
 IF wallet_account_balance_minor((SELECT escrow_account_id FROM escrow_contracts WHERE id=contract))<>50000 THEN RAISE EXCEPTION'ESC04: approval moved funds';END IF;
END $$;
ROLLBACK;
SELECT 'escrow release approval schema tests passed' AS result;
