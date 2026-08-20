SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID:='00000000-0000-4000-8000-000000000101'; owner UUID:='00000000-0000-4000-8000-000000000101'; payer UUID; checker UUID; beneficiary UUID; wallet UUID; contract UUID; source UUID; escrow UUID; funding UUID; replay UUID; result JSONB; before_wallet BIGINT; failed BOOLEAN; now_at TIMESTAMPTZ:=date_trunc('second',NOW());
BEGIN
 SELECT w.user_id,w.id,item.financial_account_id INTO payer,wallet,source FROM wallet_ledger_migration_items item
 JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id AND cutover.organization_id=item.organization_id AND cutover.status='active'
 JOIN user_wallets w ON w.id=item.source_id AND w.organization_id=item.organization_id
 WHERE item.organization_id=org AND item.source_type='wallet' LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('esc02-checker-'||gen_random_uuid()||'@example.test','test','ESC02 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',now_at);
 INSERT INTO users(email,password,name,role) VALUES('esc02-beneficiary-'||gen_random_uuid()||'@example.test','test','ESC02 Beneficiary','farmer') RETURNING id INTO beneficiary;
 result:=create_escrow_contract_draft(org,owner,payer,beneficiary,'NGN',50000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery')),jsonb_build_object('mode','single_release'),jsonb_build_array(checker),now_at+INTERVAL '7 days',now_at+INTERVAL '14 days','esc02-create-001',now_at);
 contract:=(result->>'id')::UUID; PERFORM activate_escrow_contract(org,checker,contract,'esc02-activate-001',now_at);
 PERFORM atomic_wallet_credit(wallet,1000,'COLLECTION','esc02-wallet-credit-001'); before_wallet:=wallet_account_balance_minor(source);
 result:=fund_escrow_contract_from_wallet(org,payer,contract,'esc02-funding-001','00000000-0000-4000-8000-000000000901',now_at); funding:=(result->>'id')::UUID; escrow:=(result->>'escrow_account_id')::UUID;
 replay:=(fund_escrow_contract_from_wallet(org,payer,contract,'esc02-funding-001','00000000-0000-4000-8000-000000000901',now_at+INTERVAL '1 second')->>'id')::UUID;
 IF funding IS NULL OR replay<>funding OR wallet_account_balance_minor(source)<>before_wallet-50000 OR wallet_account_balance_minor(escrow)<>50000 THEN RAISE EXCEPTION 'ESC02: funding balances or replay failed'; END IF;
 IF (SELECT state FROM escrow_contracts WHERE id=contract)<>'funded' OR (SELECT count(*) FROM journal_lines WHERE journal_entry_id=(result->>'journal_entry_id')::UUID)<>2 THEN RAISE EXCEPTION 'ESC02: funded state or journal evidence failed'; END IF;
 failed:=FALSE; BEGIN PERFORM fund_escrow_contract_from_wallet(org,checker,contract,'esc02-outsider-001',gen_random_uuid(),now_at); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%unavailable to this payer%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'ESC02: non-payer funded contract'; END IF;
 IF has_table_privilege('service_role','public.escrow_fundings','UPDATE') THEN RAISE EXCEPTION 'ESC02: funding evidence is mutable'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow wallet funding schema tests passed' AS result;
