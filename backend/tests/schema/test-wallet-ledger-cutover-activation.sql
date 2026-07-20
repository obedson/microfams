DO $$
DECLARE
  readiness wallet_ledger_migration_runs;
  cutover wallet_ledger_cutovers;
  blocked_run_id UUID;
  wallet_id UUID;
  opening_count INTEGER;
BEGIN
  SELECT * INTO readiness FROM wallet_ledger_migration_runs
  WHERE organization_id = '00000000-0000-4000-8000-000000000101'
  ORDER BY completed_at DESC LIMIT 1;

  SELECT id INTO wallet_id FROM user_wallets
  WHERE organization_id = readiness.organization_id ORDER BY id LIMIT 1;
  UPDATE user_wallets SET balance = balance + 1 WHERE id = wallet_id;
  BEGIN
    PERFORM activate_wallet_ledger_cutover(
      readiness.organization_id, readiness.id, '00000000-0000-4000-8000-000000000101'
    );
    RAISE EXCEPTION 'stale readiness controls were activated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'stale readiness controls were activated' THEN RAISE; END IF;
  END;
  UPDATE user_wallets SET balance = balance - 1 WHERE id = wallet_id;

  BEGIN
    PERFORM activate_wallet_ledger_cutover(
      readiness.organization_id, readiness.id, '00000000-0000-4000-8000-000000000102'
    );
    RAISE EXCEPTION 'unauthorized actor activated wallet cutover';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'unauthorized actor activated wallet cutover' THEN RAISE; END IF;
  END;

  cutover := activate_wallet_ledger_cutover(
    readiness.organization_id, readiness.id, '00000000-0000-4000-8000-000000000101'
  );
  IF cutover.status <> 'active' THEN RAISE EXCEPTION 'wallet cutover did not activate'; END IF;
  IF (SELECT count(*) FROM wallet_ledger_migration_items WHERE migration_run_id = readiness.id) <> 2 THEN
    RAISE EXCEPTION 'wallet cutover did not map every tenant wallet and group';
  END IF;
  SELECT count(*) INTO opening_count FROM journal_entries
  WHERE organization_id = readiness.organization_id AND source_domain = 'migration.wallet_opening';
  IF opening_count <> 2 THEN RAISE EXCEPTION 'opening balances did not produce two journals'; END IF;
  IF EXISTS (
    SELECT 1 FROM wallet_ledger_migration_items item
    JOIN financial_account_balances balance ON balance.account_id = item.financial_account_id
    WHERE item.migration_run_id = readiness.id
      AND balance.credit_total_minor <> item.amount_minor
  ) THEN RAISE EXCEPTION 'opening journal does not match a wallet control balance'; END IF;

  BEGIN
    UPDATE user_wallets SET balance = balance + 1 WHERE id = wallet_id;
    RAISE EXCEPTION 'active cutover allowed a direct wallet cache write';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'active cutover allowed a direct wallet cache write' THEN RAISE; END IF;
  END;

  SELECT id INTO blocked_run_id FROM wallet_ledger_migration_runs
  WHERE organization_id = '00000000-0000-4000-8000-000000000102'
  ORDER BY completed_at DESC LIMIT 1;
  BEGIN
    PERFORM activate_wallet_ledger_cutover(
      '00000000-0000-4000-8000-000000000102', blocked_run_id,
      '00000000-0000-4000-8000-000000000102'
    );
    RAISE EXCEPTION 'blocked readiness audit was activated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'blocked readiness audit was activated' THEN RAISE; END IF;
  END;

  cutover := rollback_wallet_ledger_cutover(
    readiness.organization_id, '00000000-0000-4000-8000-000000000101'
  );
  IF cutover.status <> 'rolled_back' THEN RAISE EXCEPTION 'wallet cutover did not roll back'; END IF;
  IF EXISTS (
    SELECT 1 FROM wallet_ledger_migration_items
    WHERE migration_run_id = readiness.id AND amount_minor > 0 AND reversal_journal_entry_id IS NULL
  ) THEN RAISE EXCEPTION 'opening journal rollback is incomplete'; END IF;
  IF EXISTS (
    SELECT 1 FROM wallet_ledger_migration_items item
    JOIN financial_account_balances balance ON balance.account_id = item.financial_account_id
    WHERE item.migration_run_id = readiness.id AND balance.net_debit_minor <> 0
  ) THEN RAISE EXCEPTION 'wallet liability account did not return to zero after rollback'; END IF;

  UPDATE user_wallets SET balance = balance + 1 WHERE id = wallet_id;
  IF (SELECT balance FROM user_wallets WHERE id = wallet_id) <> 26.50 THEN
    RAISE EXCEPTION 'rolled-back cutover did not restore legacy cache writes';
  END IF;

  readiness := audit_wallet_ledger_cutover(
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101'
  );
  cutover := activate_wallet_ledger_cutover(
    readiness.organization_id, readiness.id, '00000000-0000-4000-8000-000000000101'
  );
  IF cutover.status <> 'active' OR cutover.migration_run_id <> readiness.id
    OR (SELECT count(*) FROM wallet_ledger_migration_items WHERE migration_run_id = readiness.id) <> 2 THEN
    RAISE EXCEPTION 'corrected readiness run could not be reactivated';
  END IF;
  cutover := rollback_wallet_ledger_cutover(
    readiness.organization_id, '00000000-0000-4000-8000-000000000101'
  );
  IF cutover.status <> 'rolled_back' THEN RAISE EXCEPTION 'reactivated cutover did not roll back'; END IF;
END $$;

GRANT SELECT ON wallet_ledger_cutovers, wallet_ledger_migration_items TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM wallet_ledger_cutovers) <> 1
    OR (SELECT count(*) FROM wallet_ledger_migration_items) <> 4 THEN
    RAISE EXCEPTION 'tenant cannot read its wallet cutover records';
  END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM wallet_ledger_cutovers) <> 0
    OR (SELECT count(*) FROM wallet_ledger_migration_items) <> 0 THEN
    RAISE EXCEPTION 'wallet cutover records leaked across tenants';
  END IF;
END $$;
RESET ROLE;
