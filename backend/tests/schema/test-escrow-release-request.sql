SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101';owner UUID:=org;payer UUID;beneficiary UUID;checker UUID;wallet UUID;contract UUID;result JSONB;replay UUID;now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 INSERT INTO users(email,password,name,role)VALUES('esc03-b-'||gen_random_uuid()||'@example.test','test','ESC03 Beneficiary','farmer')RETURNING id INTO beneficiary;
 INSERT INTO users(email,password,name,role)VALUES('esc03-c-'||gen_random_uuid()||'@example.test','test','ESC03 Checker','farmer')RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(checker),now_at+INTERVAL '7 days',now_at+INTERVAL '14 days','esc03-create-001',now_at);
 contract:=(result->>'id')::UUID;PERFORM activate_escrow_contract(org,checker,contract,'esc03-activate-001',now_at);
 PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc03-credit-001');PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc03-funding-001','00000000-0000-4000-8000-000000000903',now_at);
 result:=request_escrow_release(org,checker,contract,0,30000,jsonb_build_object('delivery_note','sha256:abc'),'esc03-release-001',now_at);
 replay:=(request_escrow_release(org,checker,contract,0,30000,jsonb_build_object('delivery_note','sha256:abc'),'esc03-release-001',now_at+INTERVAL '1 second')->>'id')::UUID;
 IF result->>'state'<>'pending' OR replay<>(result->>'id')::UUID OR(SELECT state FROM escrow_contracts WHERE id=contract)<>'release_pending' THEN RAISE EXCEPTION 'ESC03: request failed';END IF;
 IF wallet_account_balance_minor((SELECT escrow_account_id FROM escrow_contracts WHERE id=contract))<>50000 THEN RAISE EXCEPTION 'ESC03: funds moved';END IF;
 IF has_table_privilege('service_role','public.escrow_release_requests','UPDATE')THEN RAISE EXCEPTION 'ESC03: mutable evidence';END IF;
END $$;
ROLLBACK;
SELECT 'escrow release request schema tests passed' AS result;
