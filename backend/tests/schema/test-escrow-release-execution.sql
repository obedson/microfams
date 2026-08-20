SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101';owner UUID:=org;payer UUID;beneficiary UUID;checker UUID;wallet UUID;beneficiary_wallet UUID;contract UUID;request_id UUID;result JSONB;replay UUID;before_beneficiary BIGINT;now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 SELECT w.user_id,w.id INTO beneficiary,beneficiary_wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' AND w.user_id<>payer LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc05-checker-'||gen_random_uuid()||'@example.test','test','ESC05 Checker','farmer') RETURNING id INTO checker; INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(to_jsonb(checker::TEXT)),now_at+INTERVAL'7 days',now_at+INTERVAL'14 days','esc05-create-001',now_at);contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc05-activate-001',now_at);PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc05-credit-001');PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc05-funding-001','00000000-0000-4000-8000-000000000905',now_at);
 result:=request_escrow_release(org,beneficiary,contract,0,50000,jsonb_build_object('delivery_note','sha256:ghi'),'esc05-request-001',now_at);request_id:=(result->>'id')::UUID;
 PERFORM decide_escrow_release(org,checker,request_id,'approve','Evidence verified','esc05-approve-001',now_at);
 before_beneficiary:=wallet_account_balance_minor((SELECT financial_account_id FROM wallet_ledger_migration_items WHERE organization_id=org AND source_type='wallet' AND source_id=beneficiary_wallet LIMIT 1));
 result:=execute_escrow_release(org,checker,request_id,'00000000-0000-4000-8000-000000000906',now_at);replay:=(execute_escrow_release(org,checker,request_id,'00000000-0000-4000-8000-000000000906',now_at+INTERVAL'1 second')->>'release_journal_entry_id')::UUID;
 IF result->>'release_journal_entry_id' IS NULL OR replay<>(result->>'release_journal_entry_id')::UUID OR(SELECT state FROM escrow_contracts WHERE id=contract)<>'released'THEN RAISE EXCEPTION'ESC05: execution failed';END IF;
 IF wallet_account_balance_minor((SELECT escrow_account_id FROM escrow_contracts WHERE id=contract))<>0 OR wallet_account_balance_minor((SELECT financial_account_id FROM wallet_ledger_migration_items WHERE organization_id=org AND source_type='wallet' AND source_id=beneficiary_wallet LIMIT 1))<>before_beneficiary+50000 THEN RAISE EXCEPTION'ESC05: balances incorrect';END IF;
END $$;
ROLLBACK;
SELECT 'escrow release execution schema tests passed' AS result;
