SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101'; owner UUID:=org; payer UUID; beneficiary UUID; checker UUID; contract UUID; result JSONB; replay JSONB; at_time TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id INTO payer FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 SELECT w.user_id INTO beneficiary FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' AND w.user_id<>payer LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc08-checker-'||gen_random_uuid()||'@example.test','test','ESC08 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',at_time);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Expiry test',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(to_jsonb(checker::TEXT)),at_time+INTERVAL'1 hour',at_time+INTERVAL'2 hours','esc08-create-001',at_time); contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc08-activate-001',at_time);
 result:=expire_escrow_contract(org,checker,contract,'esc08-expire-001',at_time+INTERVAL'3 hours'); replay:=expire_escrow_contract(org,checker,contract,'esc08-expire-001',at_time+INTERVAL'4 hours');
 IF result->>'state'<>'cancelled' OR replay->>'id'<>result->>'id' OR (SELECT count(*) FROM escrow_contract_events WHERE contract_id=contract AND action='expired')<>1 THEN RAISE EXCEPTION 'ESC08: expiry evidence or replay failed'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow expiry servicing schema tests passed' AS result;
