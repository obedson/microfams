SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101'; owner UUID:=org; payer UUID; beneficiary UUID; checker UUID; wallet UUID; contract UUID; result JSONB; replay JSONB; at_time TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id INTO payer,wallet FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers c ON c.migration_run_id=i.migration_run_id AND c.organization_id=i.organization_id AND c.status='active' JOIN user_wallets w ON w.id=i.source_id AND w.organization_id=i.organization_id WHERE i.organization_id=org AND i.source_type='wallet' LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc06-beneficiary-'||gen_random_uuid()||'@example.test','test','ESC06 Beneficiary','farmer') RETURNING id INTO beneficiary;
 INSERT INTO users(email,password,name,role) VALUES('esc06-checker-'||gen_random_uuid()||'@example.test','test','ESC06 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',at_time);
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(to_jsonb(checker::TEXT)),at_time+INTERVAL'7 days',at_time+INTERVAL'14 days','esc06-create-001',at_time); contract:=(result->>'id')::UUID;
 PERFORM activate_escrow_contract(org,checker,contract,'esc06-activate-001',at_time); PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc06-credit-001'); PERFORM fund_escrow_contract_from_wallet(org,payer,contract,'esc06-funding-001','00000000-0000-4000-8000-000000000907',at_time);
 result:=open_escrow_dispute(org,payer,contract,'delivery_failure','The agreed delivery was not completed and requires review.','esc06-dispute-001','00000000-0000-4000-8000-000000000908',at_time);
 replay:=open_escrow_dispute(org,payer,contract,'delivery_failure','The agreed delivery was not completed and requires review.','esc06-dispute-001','00000000-0000-4000-8000-000000000908',at_time+INTERVAL'1 second');
 IF result->>'id' IS NULL OR replay->>'id'<>result->>'id' OR (SELECT state FROM escrow_contracts WHERE id=contract)<>'disputed' THEN RAISE EXCEPTION 'ESC06: dispute opening or replay failed'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow dispute handling schema tests passed' AS result;
