SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101'; payer UUID; beneficiary UUID; checker UUID; wallet UUID; contract UUID; dispute UUID; result JSONB; replay JSONB; now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 SELECT w.user_id INTO beneficiary FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' AND w.user_id<>payer LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc09-checker-'||gen_random_uuid()||'@example.test','test','ESC09 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 result:=create_escrow_contract_draft(org,org,payer,beneficiary,'NGN',50000,'Resolution test',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(to_jsonb(checker::TEXT)),now_at+INTERVAL'1 hour',now_at+INTERVAL'2 hours','esc09-create-001',now_at); contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc09-activate-001',now_at);
 PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc09-credit-001'); PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc09-funding-001','00000000-0000-4000-0000-000000000911',now_at);
 result:=open_escrow_dispute(org,payer,contract,'issue','The dispute requires independent review and resolution.','esc09-open-001','00000000-0000-4000-0000-000000000910',now_at); dispute:=(result->>'id')::UUID;
 result:=resolve_escrow_dispute(org,checker,dispute,'Resolution recorded without financial movement.','esc09-resolve-001',now_at); replay:=resolve_escrow_dispute(org,checker,dispute,'Resolution recorded without financial movement.','esc09-resolve-001',now_at+INTERVAL'1 second');
 IF result->>'state'<>'resolved' OR replay->>'id'<>result->>'id' OR (SELECT state FROM escrow_contracts WHERE id=contract)<>'resolved' THEN RAISE EXCEPTION 'ESC09: resolution failed'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow dispute resolution schema tests passed' AS result;
