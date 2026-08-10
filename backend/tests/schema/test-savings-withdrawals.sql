-- SAV-04 contract: governed, tenant-isolated savings withdrawals settle exactly
-- once into the member wallet under the accepted lock, fee, and return rules.
SET search_path=public,extensions;

DO $$
DECLARE
  org_id UUID:='00000000-0000-4000-8000-000000000101';
  owner_id UUID:='00000000-0000-4000-8000-000000000101';
  member_id UUID; checker_id UUID; outsider_id UUID; member_wallet_id UUID;
  blocked_product UUID; blocked_enrolment UUID;
  fee_product UUID; fee_enrolment UUID; fee_withdrawal UUID; fee_journal UUID; fee_destination UUID;
  forfeit_product UUID; forfeit_version UUID; forfeit_enrolment UUID; forfeit_withdrawal UUID; forfeit_batch UUID;
  recovery_product UUID; recovery_enrolment UUID; reserved_withdrawal UUID; recovery_withdrawal UUID;
  identity_product UUID; identity_enrolment UUID; original_nin_verified BOOLEAN;
  period_start DATE:=CURRENT_DATE-30; result JSONB; replay_id UUID; wallet_before BIGINT; failed BOOLEAN;
BEGIN
  SELECT w.id,w.user_id INTO member_wallet_id,member_id
  FROM wallet_ledger_migration_items item
  JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
    AND cutover.organization_id=item.organization_id AND cutover.status='active'
  JOIN user_wallets w ON w.id=item.source_id AND w.organization_id=item.organization_id
  JOIN organization_memberships membership ON membership.organization_id=w.organization_id
    AND membership.user_id=w.user_id AND membership.status='active'
  WHERE item.organization_id=org_id AND item.source_type='wallet' LIMIT 1;
  IF member_wallet_id IS NULL THEN RAISE EXCEPTION 'SAV04: cutover wallet fixture is unavailable'; END IF;
  UPDATE organization_memberships
    SET permissions=array_append(permissions,'financial.savings.configure')
  WHERE organization_id=org_id AND user_id=member_id AND status='active'
    AND NOT(permissions @> ARRAY['financial.savings.configure']::TEXT[]);

  INSERT INTO users(email,password,name,role) VALUES(
    'sav04-checker-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV04 Checker','farmer')
    RETURNING id INTO checker_id;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
    VALUES(org_id,checker_id,'finance_manager',ARRAY['financial.savings.configure'],'active',NOW());
  INSERT INTO users(email,password,name,role) VALUES(
    'sav04-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','SAV04 Outsider','farmer')
    RETURNING id INTO outsider_id;

  -- The accepted blocked rule is enforced before any withdrawal record is made.
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV04.BLOCK','SAV04 blocked savings','NGN',10000,1000000,
    'manual',NULL,90,0,'blocked',0,'none',0,'actual_365','2026.4',repeat('a',64),'{}'::JSONB,
    'sav04-block-product-create-001',period_start::TIMESTAMPTZ);
  blocked_product:=(result->'product'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,blocked_product,1,'sav04-block-product-submit-001',period_start::TIMESTAMPTZ);
  PERFORM approve_savings_product(org_id,checker_id,blocked_product,1,'sav04-block-product-approve-001',period_start::TIMESTAMPTZ);
  result:=enrol_savings_product(org_id,member_id,blocked_product,NULL,'2026.4',repeat('a',64),
    'sav04-block-enrol-001',period_start::TIMESTAMPTZ);
  blocked_enrolment:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav04-block-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,blocked_enrolment,100000,'sav04-block-contribution-001',
    '00000000-0000-4000-8000-000000000a01',period_start::TIMESTAMPTZ);
  failed:=FALSE;
  BEGIN
    PERFORM request_savings_withdrawal(org_id,member_id,blocked_enrolment,50000,'sav04-block-request-001',
      '00000000-0000-4000-8000-000000000a02',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%blocked%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV04: locked product accepted an early withdrawal'; END IF;

  -- A disclosed fixed fee is snapshotted and posted to revenue; only net funds reach the wallet.
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV04.FEE','SAV04 fee savings','NGN',10000,1000000,
    'manual',NULL,90,0,'fee',500,'none',0,'actual_365','2026.4',repeat('b',64),'{}'::JSONB,
    'sav04-fee-product-create-001',period_start::TIMESTAMPTZ);
  fee_product:=(result->'product'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,fee_product,1,'sav04-fee-product-submit-001',period_start::TIMESTAMPTZ);
  PERFORM approve_savings_product(org_id,checker_id,fee_product,1,'sav04-fee-product-approve-001',period_start::TIMESTAMPTZ);
  result:=enrol_savings_product(org_id,member_id,fee_product,NULL,'2026.4',repeat('b',64),
    'sav04-fee-enrol-001',period_start::TIMESTAMPTZ);
  fee_enrolment:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav04-fee-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,fee_enrolment,100000,'sav04-fee-contribution-001',
    '00000000-0000-4000-8000-000000000a03',period_start::TIMESTAMPTZ);
  result:=request_savings_withdrawal(org_id,member_id,fee_enrolment,50000,'sav04-fee-request-001',
    '00000000-0000-4000-8000-000000000a04',NOW());
  fee_withdrawal:=(result->>'id')::UUID;
  fee_destination:=(result->>'destination_account_id')::UUID;
  replay_id:=(request_savings_withdrawal(org_id,member_id,fee_enrolment,50000,'sav04-fee-request-001',
    '00000000-0000-4000-8000-000000000a04',NOW())->>'id')::UUID;
  IF replay_id<>fee_withdrawal OR (result->>'fee_minor')::BIGINT<>500
    OR (result->>'net_payout_minor')::BIGINT<>49500 OR result->>'state'<>'pending_approval'
  THEN RAISE EXCEPTION 'SAV04: fee snapshot or request replay is incorrect: %',result; END IF;
  failed:=FALSE;
  BEGIN
    PERFORM review_savings_withdrawal(org_id,member_id,fee_withdrawal,'approve',NULL,
      'sav04-fee-self-approve-001','00000000-0000-4000-8000-000000000a05',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Maker cannot%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV04: maker approved their own withdrawal'; END IF;
  wallet_before:=wallet_account_balance_minor(fee_destination);
  result:=review_savings_withdrawal(org_id,checker_id,fee_withdrawal,'approve',NULL,
    'sav04-fee-approve-001','00000000-0000-4000-8000-000000000a06',NOW());
  replay_id:=(review_savings_withdrawal(org_id,checker_id,fee_withdrawal,'approve',NULL,
    'sav04-fee-approve-001','00000000-0000-4000-8000-000000000a06',NOW())->>'id')::UUID;
  fee_journal:=(result->>'journal_entry_id')::UUID;
  IF result->>'state'<>'settled' OR replay_id<>fee_withdrawal OR fee_journal IS NULL
    OR wallet_account_balance_minor(fee_destination)<>wallet_before+49500
  THEN RAISE EXCEPTION 'SAV04: fee withdrawal was not settled exactly once: %',result; END IF;
  IF EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=fee_journal GROUP BY journal_entry_id
      HAVING sum(CASE WHEN side='debit' THEN amount_minor ELSE -amount_minor END)<>0)
    OR NOT EXISTS(SELECT 1 FROM journal_lines line JOIN financial_accounts account ON account.id=line.account_id
      WHERE line.journal_entry_id=fee_journal AND line.side='credit' AND line.amount_minor=500
        AND account.purpose='platform_fee_revenue')
  THEN RAISE EXCEPTION 'SAV04: fee withdrawal journal is not balanced or lacks fee revenue'; END IF;

  -- The forfeit rule removes all available accrued return and pays only requested principal.
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV04.FORFEIT','SAV04 forfeit savings','NGN',10000,1000000,
    'manual',NULL,90,0,'forfeit_returns',0,'simple_interest',3650,'actual_365','2026.4',repeat('c',64),'{}'::JSONB,
    'sav04-forfeit-product-create-001',period_start::TIMESTAMPTZ);
  forfeit_product:=(result->'product'->>'id')::UUID;
  forfeit_version:=(result->'version'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,forfeit_product,1,'sav04-forfeit-product-submit-001',period_start::TIMESTAMPTZ);
  PERFORM approve_savings_product(org_id,checker_id,forfeit_product,1,'sav04-forfeit-product-approve-001',period_start::TIMESTAMPTZ);
  result:=enrol_savings_product(org_id,member_id,forfeit_product,NULL,'2026.4',repeat('c',64),
    'sav04-forfeit-enrol-001',period_start::TIMESTAMPTZ);
  forfeit_enrolment:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav04-forfeit-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,forfeit_enrolment,100000,'sav04-forfeit-contribution-001',
    '00000000-0000-4000-8000-000000000a07',period_start::TIMESTAMPTZ);
  result:=calculate_savings_accrual_batch(org_id,owner_id,forfeit_version,period_start,CURRENT_DATE,
    'sav04-forfeit-accrual-001','00000000-0000-4000-8000-000000000a08',NOW());
  forfeit_batch:=(result->'batch'->>'id')::UUID;
  PERFORM approve_savings_accrual_batch(org_id,checker_id,forfeit_batch,'sav04-forfeit-accrual-approve-001',
    '00000000-0000-4000-8000-000000000a09',NOW());
  result:=request_savings_withdrawal(org_id,member_id,forfeit_enrolment,50000,'sav04-forfeit-request-001',
    '00000000-0000-4000-8000-000000000a10',NOW());
  forfeit_withdrawal:=(result->>'id')::UUID;
  IF (result->>'principal_withdrawn_minor')::BIGINT<>50000 OR (result->>'return_withdrawn_minor')::BIGINT<>0
    OR (result->>'return_forfeited_minor')::BIGINT<>3000 OR (result->>'net_payout_minor')::BIGINT<>50000
  THEN RAISE EXCEPTION 'SAV04: return-forfeiture snapshot is incorrect: %',result; END IF;
  result:=review_savings_withdrawal(org_id,checker_id,forfeit_withdrawal,'approve',NULL,
    'sav04-forfeit-approve-001','00000000-0000-4000-8000-000000000a11',NOW());
  IF wallet_account_balance_minor((SELECT accrued_return_account_id FROM savings_enrolments WHERE id=forfeit_enrolment))<>0
    OR NOT EXISTS(SELECT 1 FROM journal_lines line JOIN financial_accounts account ON account.id=line.account_id
      WHERE line.journal_entry_id=(result->>'journal_entry_id')::UUID AND line.side='credit' AND line.amount_minor=3000
        AND account.purpose='savings_forfeited_return_revenue')
  THEN RAISE EXCEPTION 'SAV04: forfeited returns were not removed and recognized'; END IF;

  -- Pending withdrawals reserve liabilities; rejection/cancellation release them without a journal.
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV04.RECOVER','SAV04 recovery savings','NGN',10000,1000000,
    'manual',NULL,0,0,'allowed',0,'none',0,'actual_365','2026.4',repeat('d',64),'{}'::JSONB,
    'sav04-recovery-product-create-001',NOW());
  recovery_product:=(result->'product'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,recovery_product,1,'sav04-recovery-product-submit-001',NOW());
  PERFORM approve_savings_product(org_id,checker_id,recovery_product,1,'sav04-recovery-product-approve-001',NOW());
  result:=enrol_savings_product(org_id,member_id,recovery_product,NULL,'2026.4',repeat('d',64),
    'sav04-recovery-enrol-001',NOW());
  recovery_enrolment:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav04-recovery-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,recovery_enrolment,100000,'sav04-recovery-contribution-001',
    '00000000-0000-4000-8000-000000000a12',NOW());
  result:=request_savings_withdrawal(org_id,member_id,recovery_enrolment,80000,'sav04-reserved-request-001',
    '00000000-0000-4000-8000-000000000a13',NOW());
  reserved_withdrawal:=(result->>'id')::UUID;
  failed:=FALSE;
  BEGIN
    PERFORM request_savings_withdrawal(org_id,member_id,recovery_enrolment,30000,'sav04-over-reserved-request-001',
      '00000000-0000-4000-8000-000000000a14',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Insufficient%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV04: pending withdrawal did not reserve liabilities'; END IF;
  PERFORM review_savings_withdrawal(org_id,checker_id,reserved_withdrawal,'reject','Independent review requested a lower amount.',
    'sav04-reserved-reject-001','00000000-0000-4000-8000-000000000a15',NOW());
  result:=request_savings_withdrawal(org_id,member_id,recovery_enrolment,30000,'sav04-recovery-request-001',
    '00000000-0000-4000-8000-000000000a16',NOW());
  recovery_withdrawal:=(result->>'id')::UUID;
  PERFORM cancel_savings_withdrawal(org_id,member_id,recovery_withdrawal,'Member no longer requires this withdrawal.',
    'sav04-recovery-cancel-001','00000000-0000-4000-8000-000000000a17',NOW());
  IF EXISTS(SELECT 1 FROM savings_withdrawals WHERE id IN(reserved_withdrawal,recovery_withdrawal) AND journal_entry_id IS NOT NULL)
  THEN RAISE EXCEPTION 'SAV04: rejection or cancellation created a financial posting'; END IF;

  -- Identity policy is evaluated again at withdrawal time, not only at enrolment.
  result:=create_savings_product_draft(org_id,owner_id,'SAV.SAV04.KYC','SAV04 identity savings','NGN',10000,1000000,
    'manual',NULL,0,0,'allowed',0,'none',0,'actual_365','2026.4',repeat('e',64),
    '{"requiredIdentityTier":"nin_verified"}'::JSONB,'sav04-identity-product-create-001',NOW());
  identity_product:=(result->'product'->>'id')::UUID;
  PERFORM submit_savings_product(org_id,owner_id,identity_product,1,'sav04-identity-product-submit-001',NOW());
  PERFORM approve_savings_product(org_id,checker_id,identity_product,1,'sav04-identity-product-approve-001',NOW());
  result:=enrol_savings_product(org_id,member_id,identity_product,NULL,'2026.4',repeat('e',64),
    'sav04-identity-enrol-001',NOW());
  identity_enrolment:=(result->>'id')::UUID;
  PERFORM atomic_wallet_credit(member_wallet_id,1200,'COLLECTION','sav04-identity-wallet-funding-001');
  PERFORM post_savings_contribution(org_id,member_id,identity_enrolment,100000,'sav04-identity-contribution-001',
    '00000000-0000-4000-8000-000000000a18',NOW());
  SELECT nin_verified INTO original_nin_verified FROM users WHERE id=member_id;
  UPDATE users SET nin_verified=FALSE WHERE id=member_id;
  failed:=FALSE;
  BEGIN
    PERFORM request_savings_withdrawal(org_id,member_id,identity_enrolment,10000,'sav04-identity-request-001',
      '00000000-0000-4000-8000-000000000a19',NOW());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%Verified identity%' THEN failed:=TRUE; END IF; END;
  UPDATE users SET nin_verified=original_nin_verified WHERE id=member_id;
  IF NOT failed THEN RAISE EXCEPTION 'SAV04: identity-gated withdrawal bypassed KYC'; END IF;

  IF jsonb_array_length(list_member_savings_withdrawals(org_id,member_id,recovery_enrolment))<>2
    OR jsonb_array_length(list_savings_withdrawal_reviews(org_id,checker_id))<4
  THEN RAISE EXCEPTION 'SAV04: servicing reads are incomplete'; END IF;
  failed:=FALSE;
  BEGIN PERFORM list_member_savings_withdrawals(org_id,outsider_id,recovery_enrolment);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%not found%' THEN failed:=TRUE; END IF; END;
  IF NOT failed THEN RAISE EXCEPTION 'SAV04: outsider read member withdrawal evidence'; END IF;

  -- Leave a known pending request for the process-level exactly-once race test.
  result:=request_savings_withdrawal(org_id,member_id,recovery_enrolment,50000,'sav04-concurrency-request-001',
    '00000000-0000-4000-8000-000000000a20',NOW());
  IF result->>'state'<>'pending_approval' THEN RAISE EXCEPTION 'SAV04: concurrency fixture is invalid'; END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE blocked BOOLEAN:=FALSE;
BEGIN
  BEGIN
    INSERT INTO savings_withdrawals(organization_id,enrolment_id,product_version_id,member_id,destination_wallet_id,
      destination_account_id,principal_account_id,accrued_return_account_id,currency,requested_minor,
      principal_withdrawn_minor,return_withdrawn_minor,return_forfeited_minor,fee_minor,net_payout_minor,is_early,
      early_withdrawal_rule,disclosure_version,disclosure_hash,allocation_version,principal_balance_snapshot_minor,
      return_balance_snapshot_minor,created_by,creation_idempotency_key,creation_request_hash,creation_correlation_id,created_at)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      gen_random_uuid(),gen_random_uuid(),'NGN',1,1,0,0,0,1,FALSE,'allowed','forged',repeat('a',64),
      'returns_then_principal_v1',1,0,gen_random_uuid(),'forged-sav04-withdrawal',repeat('a',64),gen_random_uuid(),NOW());
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; END;
  IF NOT blocked THEN RAISE EXCEPTION 'SAV04: service role directly inserted a withdrawal'; END IF;
END $$;
RESET ROLE;
