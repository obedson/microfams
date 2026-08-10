-- SAV-02 contract: balanced contributions, holds, standing-order no-debt
-- failures, deterministic servicing, lifecycle control, and tenant isolation.
SET search_path=public,extensions;

DO $$
DECLARE
  org_id UUID:='00000000-0000-4000-8000-000000000101';
  owner_id UUID:='00000000-0000-4000-8000-000000000101'; member_id UUID;
  checker_id UUID; product_id UUID; enrolment_id UUID; wallet_id UUID; outsider_id UUID;
  mandate_id UUID; contribution_id UUID; replay_id UUID; failed BOOLEAN; result JSONB;
  source_account_id UUID; principal_ledger_account_id UUID; starting_wallet BIGINT; starting_principal BIGINT;
  now_at TIMESTAMPTZ:=date_trunc('second',NOW());
  second_due TIMESTAMPTZ;
BEGIN
  SELECT w.id,w.user_id INTO wallet_id,member_id
  FROM wallet_ledger_migration_items item
  JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
    AND cutover.organization_id=item.organization_id AND cutover.status='active'
  JOIN user_wallets w ON w.id=item.source_id AND w.organization_id=item.organization_id
  JOIN organization_memberships membership ON membership.organization_id=w.organization_id
    AND membership.user_id=w.user_id AND membership.status='active'
  WHERE item.organization_id=org_id AND item.source_type='wallet' LIMIT 1;
  IF wallet_id IS NULL THEN RAISE EXCEPTION 'SAV02: cutover wallet fixture is unavailable'; END IF;
  INSERT INTO users(email,password,name,role) VALUES(
    'sav02-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV02 Checker','farmer')
    RETURNING id INTO checker_id;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(org_id,checker_id,'finance_manager',ARRAY['financial.savings.configure'],'active',now_at);
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV02','SAV02 recurring savings','NGN',10000,1000000,
    'monthly',NULL,0,0,'allowed',0,'none',0,'actual_365','2026.2',repeat('c',64),'{}'::JSONB,
    'sav02-product-create-001',now_at);
  product_id:=(result->'product'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,product_id,1,'sav02-product-submit-001',now_at);
  PERFORM approve_savings_product(org_id,checker_id,product_id,1,'sav02-product-approve-001',now_at);
  result:=enrol_savings_product(org_id,member_id,product_id,NULL,'2026.2',repeat('c',64),
    'sav02-enrolment-create-001',now_at);
  enrolment_id:=(result->>'id')::UUID;
  IF org_id IS NULL OR wallet_id IS NULL OR NOT wallet_cutover_is_active(org_id) THEN
    RAISE EXCEPTION 'SAV02: active savings wallet fixture is unavailable';
  END IF;
  SELECT item.financial_account_id INTO source_account_id FROM wallet_ledger_migration_items item
    JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
      AND cutover.organization_id=item.organization_id AND cutover.status='active'
    WHERE item.organization_id=org_id AND item.source_type='wallet' AND item.source_id=wallet_id;
  IF (SELECT purpose FROM financial_accounts WHERE id=source_account_id) IS DISTINCT FROM 'individual_wallet_funds' THEN
    RAISE EXCEPTION 'SAV02: cutover wallet was not bound to the canonical purpose';
  END IF;
  SELECT principal_account_id INTO principal_ledger_account_id FROM savings_enrolments WHERE id=enrolment_id;
  starting_wallet:=wallet_account_balance_minor(source_account_id);
  starting_principal:=wallet_account_balance_minor(principal_ledger_account_id);

  PERFORM atomic_wallet_credit(wallet_id,1200,'COLLECTION','sav02-wallet-funding-001');
  result:=post_savings_contribution(org_id,member_id,enrolment_id,20000,'sav02-manual-contribution-001',
    '00000000-0000-4000-8000-000000000811',now_at);
  contribution_id:=(result->>'id')::UUID;
  replay_id:=(post_savings_contribution(org_id,member_id,enrolment_id,20000,'sav02-manual-contribution-001',
    '00000000-0000-4000-8000-000000000811',now_at+INTERVAL '1 second')->>'id')::UUID;
  IF contribution_id IS NULL OR replay_id<>contribution_id THEN RAISE EXCEPTION 'SAV02: manual replay was not idempotent'; END IF;
  PERFORM reserve_wallet_funds(wallet_id,wallet_account_balance_minor(source_account_id)-50000,
    'sav02-held-funds','sav02-wallet-hold-001',
    '00000000-0000-4000-8000-000000000812',member_id,now_at+INTERVAL '30 minutes');

  failed:=FALSE;
  BEGIN
    PERFORM post_savings_contribution(org_id,member_id,enrolment_id,21000,'sav02-manual-contribution-001',
      '00000000-0000-4000-8000-000000000811',now_at);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%different contribution facts%' THEN failed:=TRUE; END IF;
  END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV02: changed idempotent contribution was accepted'; END IF;

  result:=create_savings_standing_order(org_id,member_id,enrolment_id,90000,now_at+INTERVAL '1 minute',
    '2026.2',repeat('c',64),'sav02-standing-order-create-001',now_at);
  mandate_id:=(result->>'id')::UUID;
  result:=service_savings_standing_order(org_id,mandate_id,'sav02-worker',now_at+INTERVAL '1 minute');
  IF result->>'state'<>'failed' OR result->>'failure_code'<>'insufficient_funds' THEN
    RAISE EXCEPTION 'SAV02: insufficient recurring contribution did not fail safely: %',result;
  END IF;
  IF (SELECT count(*) FROM savings_contributions WHERE standing_order_id=mandate_id)<>0 THEN
    RAISE EXCEPTION 'SAV02: failed standing order created debt or a contribution';
  END IF;

  SELECT next_due_at INTO second_due FROM savings_standing_orders WHERE id=mandate_id;
  result:=service_savings_standing_order(org_id,mandate_id,'sav02-worker',second_due);
  IF result->>'state'<>'succeeded' OR result->>'contribution_id' IS NULL THEN
    RAISE EXCEPTION 'SAV02: funded standing order did not post: %',result;
  END IF;
  IF (SELECT count(*) FROM savings_contributions contribution
      WHERE contribution.organization_id=org_id
        AND contribution.enrolment_id=(SELECT mandate.enrolment_id FROM savings_standing_orders mandate WHERE mandate.id=mandate_id))<>2 THEN
    RAISE EXCEPTION 'SAV02: contribution history is incomplete';
  END IF;
  IF EXISTS(
    SELECT 1 FROM journal_entries j JOIN journal_lines l ON l.journal_entry_id=j.id
    WHERE j.id IN(SELECT contribution.journal_entry_id FROM savings_contributions contribution
      WHERE contribution.enrolment_id=(SELECT mandate.enrolment_id FROM savings_standing_orders mandate WHERE mandate.id=mandate_id))
    GROUP BY j.id HAVING sum(CASE WHEN l.side='debit' THEN l.amount_minor ELSE -l.amount_minor END)<>0
  ) THEN RAISE EXCEPTION 'SAV02: a contribution journal is unbalanced'; END IF;
  IF wallet_account_balance_minor(source_account_id)<>starting_wallet+10000
    OR wallet_account_balance_minor(principal_ledger_account_id)<>starting_principal+110000
  THEN RAISE EXCEPTION 'SAV02: wallet or savings balance is incorrect'; END IF;

  PERFORM transition_savings_standing_order(org_id,member_id,mandate_id,'pause','sav02-standing-pause-001',second_due+INTERVAL '1 minute');
  PERFORM transition_savings_standing_order(org_id,member_id,mandate_id,'resume','sav02-standing-resume-001',second_due+INTERVAL '2 minutes');
  PERFORM transition_savings_standing_order(org_id,member_id,mandate_id,'cancel','sav02-standing-cancel-001',second_due+INTERVAL '3 minutes');
  IF (SELECT state FROM savings_standing_orders WHERE id=mandate_id)<>'cancelled' THEN RAISE EXCEPTION 'SAV02: mandate lifecycle failed'; END IF;
  IF jsonb_array_length(list_member_savings_contributions(org_id,member_id,enrolment_id))<>2
    OR jsonb_array_length(list_member_savings_standing_orders(org_id,member_id,enrolment_id))<>1
  THEN RAISE EXCEPTION 'SAV02: member servicing reads are incomplete'; END IF;

  INSERT INTO users(email,password,name,role) VALUES(
    'sav02-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV02 Outsider','farmer') RETURNING id INTO outsider_id;
  failed:=FALSE;
  BEGIN PERFORM list_member_savings_contributions(org_id,outsider_id,enrolment_id);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not found%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV02: outsider read another member savings'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE blocked BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO savings_contributions(organization_id,enrolment_id,member_id,source_wallet_id,source_account_id,
      destination_account_id,method,currency,amount_minor,journal_entry_id,idempotency_key,request_hash,correlation_id,contributed_at)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      'manual','NGN',1,gen_random_uuid(),'forged-sav02-contribution',repeat('a',64),gen_random_uuid(),NOW());
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; END;
  IF NOT blocked THEN RAISE EXCEPTION 'SAV02: service role directly inserted a contribution'; END IF;
END $$;
RESET ROLE;
