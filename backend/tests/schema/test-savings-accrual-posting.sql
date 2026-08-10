-- SAV-03 contract: deterministic completed-day accruals, immutable snapshots,
-- independent review, balanced posting, rejection recovery, and tenant isolation.
SET search_path=public,extensions;

DO $$
DECLARE
  org_id UUID:='00000000-0000-4000-8000-000000000101';
  owner_id UUID:='00000000-0000-4000-8000-000000000101';
  member_id UUID; checker_id UUID; outsider_id UUID; member_wallet_id UUID;
  product_id UUID; version_id UUID; enrolment_id UUID; accrued_account_id UUID;
  concurrent_product_id UUID; concurrent_version_id UUID; concurrent_enrolment_id UUID;
  rejected_batch_id UUID; approved_batch_id UUID; replay_id UUID; accrual_journal_id UUID;
  period_start DATE:=CURRENT_DATE-30; period_end DATE:=CURRENT_DATE;
  result JSONB; failed BOOLEAN;
BEGIN
  SELECT w.id,w.user_id INTO member_wallet_id,member_id
  FROM wallet_ledger_migration_items item
  JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
    AND cutover.organization_id=item.organization_id AND cutover.status='active'
  JOIN user_wallets w ON w.id=item.source_id AND w.organization_id=item.organization_id
  JOIN organization_memberships membership ON membership.organization_id=w.organization_id
    AND membership.user_id=w.user_id AND membership.status='active'
  WHERE item.organization_id=org_id AND item.source_type='wallet' LIMIT 1;
  IF member_wallet_id IS NULL THEN RAISE EXCEPTION 'SAV03: cutover wallet fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES(
    'sav03-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV03 Checker','farmer')
    RETURNING id INTO checker_id;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(org_id,checker_id,'finance_manager',ARRAY['financial.savings.configure'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES(
    'sav03-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV03 Outsider','farmer')
    RETURNING id INTO outsider_id;

  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV03','SAV03 return savings','NGN',10000,1000000,
    'manual',NULL,0,0,'allowed',0,'simple_interest',3650,'actual_365','2026.3',repeat('d',64),'{}'::JSONB,
    'sav03-product-create-001',period_start::TIMESTAMPTZ);
  product_id:=(result->'product'->>'id')::UUID;
  version_id:=(result->'version'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,product_id,1,'sav03-product-submit-001',period_start::TIMESTAMPTZ);
  PERFORM approve_savings_product(org_id,checker_id,product_id,1,'sav03-product-approve-001',period_start::TIMESTAMPTZ);
  result:=enrol_savings_product(org_id,member_id,product_id,NULL,'2026.3',repeat('d',64),
    'sav03-enrolment-create-001',period_start::TIMESTAMPTZ);
  enrolment_id:=(result->>'id')::UUID;
  SELECT accrued_return_account_id INTO accrued_account_id FROM savings_enrolments WHERE id=enrolment_id;
  PERFORM release_wallet_reservation(reservation.id,member_id)
    FROM fund_reservations reservation
    WHERE reservation.wallet_id=member_wallet_id AND reservation.state='active'
      AND reservation.source_record_id='sav02-held-funds';
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav03-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,enrolment_id,100000,'sav03-contribution-001',
    '00000000-0000-4000-8000-000000000901',period_start::TIMESTAMPTZ);

  result:=calculate_savings_accrual_batch(org_id,owner_id,version_id,period_start,period_end,
    'sav03-accrual-calculate-001','00000000-0000-4000-8000-000000000902',NOW());
  rejected_batch_id:=(result->'batch'->>'id')::UUID;
  replay_id:=(calculate_savings_accrual_batch(org_id,owner_id,version_id,period_start,period_end,
    'sav03-accrual-calculate-001','00000000-0000-4000-8000-000000000902',NOW())->'batch'->>'id')::UUID;
  IF rejected_batch_id IS NULL OR replay_id<>rejected_batch_id
    OR (result->'batch'->>'total_accrued_minor')::BIGINT<>3000
    OR (result->'batch'->>'item_count')::INTEGER<>1
  THEN RAISE EXCEPTION 'SAV03: deterministic accrual or replay is incorrect: %',result; END IF;
  IF NOT EXISTS(SELECT 1 FROM savings_accrual_items WHERE batch_id=rejected_batch_id
      AND opening_principal_minor=0 AND closing_principal_minor=100000
      AND eligible_principal_days_minor=3000000 AND accrued_minor=3000
      AND annual_rate_basis_points=3650 AND day_count_convention='actual_365'
      AND formula_version='simple_interest_v1_half_up')
  THEN RAISE EXCEPTION 'SAV03: member calculation snapshot is incorrect'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM calculate_savings_accrual_batch(org_id,owner_id,version_id,period_start+1,period_end,
      'sav03-accrual-overlap-001','00000000-0000-4000-8000-000000000903',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%overlaps%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV03: overlapping accrual was accepted'; END IF;

  PERFORM reject_savings_accrual_batch(org_id,checker_id,rejected_batch_id,'Calculation held for independent evidence review.',
    'sav03-accrual-reject-001','00000000-0000-4000-8000-000000000904',NOW());
  IF (SELECT state FROM savings_accrual_batches WHERE id=rejected_batch_id)<>'rejected' THEN
    RAISE EXCEPTION 'SAV03: rejected calculation remained active';
  END IF;
  result:=calculate_savings_accrual_batch(org_id,owner_id,version_id,period_start,period_end,
    'sav03-accrual-calculate-002','00000000-0000-4000-8000-000000000905',NOW());
  approved_batch_id:=(result->'batch'->>'id')::UUID;
  IF approved_batch_id=rejected_batch_id THEN RAISE EXCEPTION 'SAV03: rejection recovery did not create new evidence'; END IF;

  failed:=FALSE;
  BEGIN
    PERFORM approve_savings_accrual_batch(org_id,owner_id,approved_batch_id,'sav03-accrual-self-approve-001',
      '00000000-0000-4000-8000-000000000906',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Maker cannot approve%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV03: maker approved their own accrual'; END IF;

  result:=approve_savings_accrual_batch(org_id,checker_id,approved_batch_id,'sav03-accrual-approve-001',
    '00000000-0000-4000-8000-000000000907',NOW());
  replay_id:=(approve_savings_accrual_batch(org_id,checker_id,approved_batch_id,'sav03-accrual-approve-001',
    '00000000-0000-4000-8000-000000000907',NOW())->>'id')::UUID;
  accrual_journal_id:=(result->>'journal_entry_id')::UUID;
  IF result->>'state'<>'posted' OR replay_id<>approved_batch_id OR accrual_journal_id IS NULL THEN
    RAISE EXCEPTION 'SAV03: independent approval or replay failed: %',result;
  END IF;
  IF (SELECT count(*) FROM journal_lines WHERE journal_entry_id=accrual_journal_id)<>2
    OR EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=accrual_journal_id GROUP BY journal_entry_id
      HAVING sum(CASE WHEN side='debit' THEN amount_minor ELSE -amount_minor END)<>0)
  THEN RAISE EXCEPTION 'SAV03: accrual journal is not balanced'; END IF;
  IF wallet_account_balance_minor(accrued_account_id)<>3000
    OR NOT EXISTS(SELECT 1 FROM journal_lines line JOIN financial_accounts account ON account.id=line.account_id
      WHERE line.journal_entry_id=accrual_journal_id AND line.side='debit' AND line.amount_minor=3000
        AND account.purpose='savings_return_expense')
  THEN RAISE EXCEPTION 'SAV03: return liability or expense posting is incorrect'; END IF;

  IF jsonb_array_length(list_member_savings_accruals(org_id,member_id,enrolment_id))<>2
    OR jsonb_array_length(list_savings_accrual_batches(org_id,checker_id))<2
  THEN RAISE EXCEPTION 'SAV03: accrual servicing reads are incomplete'; END IF;
  failed:=FALSE;
  BEGIN PERFORM list_member_savings_accruals(org_id,outsider_id,enrolment_id);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not found%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV03: outsider read member accrual evidence'; END IF;

  -- Leave a second, independently-made batch pending for the process-level race test.
  result:=create_savings_product_draft(org_id,checker_id,'SAV.SAV03.CONCURRENT','SAV03 concurrent return savings',
    'NGN',10000,1000000,'manual',NULL,0,0,'allowed',0,'simple_interest',3650,'actual_365','2026.3',repeat('e',64),
    '{}'::JSONB,'sav03-concurrent-product-create-001',period_start::TIMESTAMPTZ);
  concurrent_product_id:=(result->'product'->>'id')::UUID;
  concurrent_version_id:=(result->'version'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,checker_id,concurrent_product_id,1,
    'sav03-concurrent-product-submit-001',period_start::TIMESTAMPTZ);
  PERFORM approve_savings_product(org_id,owner_id,concurrent_product_id,1,
    'sav03-concurrent-product-approve-001',period_start::TIMESTAMPTZ);
  result:=enrol_savings_product(org_id,member_id,concurrent_product_id,NULL,'2026.3',repeat('e',64),
    'sav03-concurrent-enrolment-001',period_start::TIMESTAMPTZ);
  concurrent_enrolment_id:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav03-concurrent-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,concurrent_enrolment_id,100000,
    'sav03-concurrent-contribution-001','00000000-0000-4000-8000-000000000908',period_start::TIMESTAMPTZ);
  result:=calculate_savings_accrual_batch(org_id,checker_id,concurrent_version_id,period_start,period_end,
    'sav03-concurrency-calculate-001','00000000-0000-4000-8000-000000000909',NOW());
  IF result->'batch'->>'state'<>'pending_approval'
    OR (result->'batch'->>'total_accrued_minor')::BIGINT<>3000
  THEN RAISE EXCEPTION 'SAV03: concurrency fixture is invalid: %',result; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE blocked BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO savings_accrual_batches(organization_id,product_version_id,currency,period_start,period_end,
      return_method,annual_rate_basis_points,day_count_convention,formula_version,created_by,creation_idempotency_key,
      creation_request_hash,creation_correlation_id,created_at)
    VALUES(gen_random_uuid(),gen_random_uuid(),'NGN',CURRENT_DATE-1,CURRENT_DATE,'simple_interest',1,'actual_365',
      'simple_interest_v1_half_up',gen_random_uuid(),'forged-sav03-accrual',repeat('a',64),gen_random_uuid(),NOW());
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; END;
  IF NOT blocked THEN RAISE EXCEPTION 'SAV03: service role directly inserted an accrual batch'; END IF;
END $$;
RESET ROLE;
