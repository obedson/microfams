DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  owner_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  recipient_user_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  secondary_user_id CONSTANT UUID := '00000000-0000-4000-8000-000000000103';
  outsider_user_id CONSTANT UUID := '00000000-0000-4000-8000-000000000104';
  readiness wallet_ledger_migration_runs;
  cutover wallet_ledger_cutovers;
  owner_wallet_id UUID;
  recipient_wallet_id UUID;
  outsider_wallet_id UUID;
  group_id UUID;
  request_id UUID;
  first_tx_id UUID;
  replay_tx_id UUID;
  transfer JSONB;
  journal_count INTEGER;
BEGIN
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES (tenant_id, secondary_user_id, 'member', 'active', NOW())
  ON CONFLICT (organization_id, user_id) DO UPDATE SET status = 'active';
  INSERT INTO user_wallets(user_id, organization_id, balance)
  VALUES (secondary_user_id, tenant_id, 10.00)
  RETURNING id INTO owner_wallet_id;
  SELECT id INTO recipient_wallet_id FROM user_wallets
  WHERE user_id = recipient_user_id AND organization_id = tenant_id;
  SELECT id INTO group_id FROM groups WHERE groups.organization_id = tenant_id ORDER BY id LIMIT 1;

  readiness := audit_wallet_ledger_cutover(tenant_id, owner_id);
  IF readiness.status <> 'ready' OR readiness.wallet_count <> 2 THEN
    RAISE EXCEPTION 'posting-engine readiness audit is invalid';
  END IF;
  cutover := activate_wallet_ledger_cutover(tenant_id, readiness.id, owner_id);
  IF cutover.status <> 'active' THEN RAISE EXCEPTION 'posting-engine cutover did not activate'; END IF;

  first_tx_id := atomic_group_credit(group_id, 5.25, 'engine-group-credit');
  replay_tx_id := atomic_group_credit(group_id, 5.25, 'engine-group-credit');
  IF first_tx_id <> replay_tx_id THEN RAISE EXCEPTION 'group credit replay returned a new transaction'; END IF;
  IF (SELECT count(*) FROM journal_entries WHERE organization_id = tenant_id
      AND source_domain = 'wallet.group_credit' AND idempotency_key = 'wallet.group_credit:engine-group-credit') <> 1 THEN
    RAISE EXCEPTION 'group credit was not journal-idempotent';
  END IF;
  IF (SELECT group_fund_balance FROM groups WHERE id = group_id) <> 1505.25 THEN
    RAISE EXCEPTION 'group credit cache does not match its journal';
  END IF;
  BEGIN
    PERFORM atomic_group_credit(group_id, 6.25, 'engine-group-credit');
    RAISE EXCEPTION 'changed idempotent group credit was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'changed idempotent group credit was accepted' THEN RAISE; END IF;
  END;

  transfer := atomic_p2p_transfer(recipient_wallet_id, owner_wallet_id, 2.50, 'engine-p2p');
  IF transfer->>'journal_entry_id' IS NULL THEN RAISE EXCEPTION 'P2P transfer returned no journal'; END IF;
  IF (SELECT balance FROM user_wallets WHERE id = recipient_wallet_id) <> 24.00
    OR (SELECT balance FROM user_wallets WHERE id = owner_wallet_id) <> 12.50 THEN
    RAISE EXCEPTION 'P2P cache balances are incorrect';
  END IF;

  first_tx_id := atomic_wallet_debit(recipient_wallet_id, 24.00, 'WITHDRAWAL', 'engine-withdrawal', NULL);
  replay_tx_id := atomic_wallet_debit(recipient_wallet_id, 24.00, 'WITHDRAWAL', 'engine-withdrawal', NULL);
  IF first_tx_id <> replay_tx_id OR (SELECT balance FROM user_wallets WHERE id = recipient_wallet_id) <> 0.00 THEN
    RAISE EXCEPTION 'withdrawal reservation did not debit the wallet cache';
  END IF;
  PERFORM atomic_wallet_credit(
    recipient_wallet_id, 24.00, 'WITHDRAWAL', 'engine-withdrawal-failed',
    '{"reason":"deterministic failure"}'::JSONB
  );
  IF (SELECT balance FROM user_wallets WHERE id = recipient_wallet_id) <> 24.00 THEN
    RAISE EXCEPTION 'failed withdrawal compensation did not restore the wallet';
  END IF;
  BEGIN
    PERFORM atomic_wallet_credit(recipient_wallet_id, 1.00, 'WITHDRAWAL', 'engine-over-restoration', NULL);
    RAISE EXCEPTION 'wallet restored more than its pending payout';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'wallet restored more than its pending payout' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM atomic_wallet_debit(
      recipient_wallet_id, 1.00, 'WITHDRAWAL', 'engine-unmapped-penalty',
      '{"reason":"Grace period penalty settlement"}'::JSONB
    );
    RAISE EXCEPTION 'unmapped penalty was posted as a withdrawal';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'unmapped penalty was posted as a withdrawal' THEN RAISE; END IF;
  END;

  INSERT INTO group_consensus_requests(
    group_id, requested_by, target_user_id, amount, status, request_type
  ) VALUES (group_id, owner_id, secondary_user_id, 3.00, 'APPROVED', 'WITHDRAWAL')
  RETURNING id INTO request_id;
  transfer := atomic_group_transfer(group_id, owner_wallet_id, 3.00, 'engine-group-transfer', request_id);
  IF transfer->>'journal_entry_id' IS NULL
    OR (SELECT status FROM group_consensus_requests WHERE id = request_id) <> 'EXECUTED' THEN
    RAISE EXCEPTION 'group transfer was not journaled and executed';
  END IF;
  IF (SELECT group_fund_balance FROM groups WHERE id = group_id) <> 1502.25
    OR (SELECT balance FROM user_wallets WHERE id = owner_wallet_id) <> 15.50 THEN
    RAISE EXCEPTION 'group transfer caches are incorrect';
  END IF;
  transfer := atomic_group_transfer(group_id, owner_wallet_id, 3.00, 'engine-group-transfer', request_id);
  IF (SELECT group_fund_balance FROM groups WHERE id = group_id) <> 1502.25
    OR (SELECT balance FROM user_wallets WHERE id = owner_wallet_id) <> 15.50 THEN
    RAISE EXCEPTION 'group transfer replay changed a cache balance';
  END IF;

  BEGIN
    PERFORM atomic_wallet_debit(recipient_wallet_id, 9999, 'WITHDRAWAL', 'engine-insufficient', NULL);
    RAISE EXCEPTION 'insufficient wallet debit was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'insufficient wallet debit was accepted' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM journal_entries WHERE idempotency_key = 'wallet.debit:engine-insufficient') THEN
    RAISE EXCEPTION 'failed debit left a journal';
  END IF;

  INSERT INTO users(id, email, password, name, role)
  VALUES (outsider_user_id, 'posting-outsider@example.test', 'not-a-real-password', 'Posting Outsider', 'farmer');
  INSERT INTO user_wallets(user_id, organization_id, balance)
  VALUES (outsider_user_id, outsider_user_id, 0)
  RETURNING id INTO outsider_wallet_id;
  BEGIN
    PERFORM atomic_p2p_transfer(recipient_wallet_id, outsider_wallet_id, 1, 'engine-cross-tenant');
    RAISE EXCEPTION 'cross-tenant P2P transfer was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant P2P transfer was accepted' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM process_group_fund_payment(gen_random_uuid(), group_id, 1);
    RAISE EXCEPTION 'active cutover used an unapproved booking settlement mapping';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'active cutover used an unapproved booking settlement mapping' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE wallet_transactions SET metadata = '{"tampered":true}'::JSONB WHERE id = first_tx_id;
    RAISE EXCEPTION 'wallet evidence was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'wallet evidence was mutable' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM atomic_group_credit(group_id, 0.001, 'engine-subminor');
    RAISE EXCEPTION 'sub-minor amount was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'sub-minor amount was accepted' THEN RAISE; END IF;
  END;

  SELECT count(*) INTO journal_count FROM journal_entries
  WHERE organization_id = tenant_id AND source_domain LIKE 'wallet.%';
  IF journal_count <> 5 THEN RAISE EXCEPTION 'unexpected operational wallet journal count: %', journal_count; END IF;
  IF EXISTS (
    SELECT entry.id FROM journal_entries entry
    JOIN journal_lines line ON line.journal_entry_id = entry.id
    WHERE entry.organization_id = tenant_id AND entry.source_domain LIKE 'wallet.%'
    GROUP BY entry.id
    HAVING sum(CASE WHEN line.side = 'debit' THEN line.amount_minor ELSE -line.amount_minor END) <> 0
  ) THEN RAISE EXCEPTION 'an operational wallet journal is unbalanced'; END IF;
  IF (SELECT count(*) FROM wallet_transactions WHERE journal_entry_id IS NOT NULL
      AND organization_id = tenant_id) <> 7 THEN
    RAISE EXCEPTION 'legacy evidence is not linked one-for-one with wallet journal legs';
  END IF;
  IF EXISTS (
    SELECT 1 FROM user_wallets wallet
    JOIN financial_accounts account ON account.organization_id = wallet.organization_id
      AND account.owner_type = 'user' AND account.owner_id = wallet.user_id AND account.currency = 'NGN'
    WHERE wallet.organization_id = tenant_id
      AND wallet.balance * 100 <> wallet_account_balance_minor(account.id)
  ) OR EXISTS (
    SELECT 1 FROM groups group_record
    JOIN financial_accounts account ON account.organization_id = group_record.organization_id
      AND account.owner_type = 'group' AND account.owner_id = group_record.id AND account.currency = 'NGN'
    WHERE group_record.organization_id = tenant_id
      AND group_record.group_fund_balance * 100 <> wallet_account_balance_minor(account.id)
  ) THEN RAISE EXCEPTION 'a wallet cache does not reconcile to its liability account'; END IF;

  BEGIN
    PERFORM rollback_wallet_ledger_cutover(tenant_id, owner_id);
    RAISE EXCEPTION 'cutover with posted wallet activity rolled back';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cutover with posted wallet activity rolled back' THEN RAISE; END IF;
  END;
END $$;

SET ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM atomic_group_credit(
      (SELECT id FROM groups WHERE organization_id = '00000000-0000-4000-8000-000000000101' LIMIT 1),
      1, 'authenticated-engine-call'
    );
    RAISE EXCEPTION 'authenticated role executed the posting engine';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
