DO $$
DECLARE
  asset_account UUID;
  liability_account UUID;
  outsider_account UUID;
  entry_id UUID;
  duplicate_id UUID;
BEGIN
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on)
  VALUES
    ('00000000-0000-4000-8000-000000000101', 'FY 2026', DATE '2026-01-01', DATE '2026-12-31'),
    ('00000000-0000-4000-8000-000000000102', 'FY 2026', DATE '2026-01-01', DATE '2026-12-31');

  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency, owner_type, is_control
  ) VALUES (
    '00000000-0000-4000-8000-000000000101', '1100.CLEARING', 'Provider clearing',
    'asset', 'debit', 'NGN', 'system', TRUE
  ) RETURNING id INTO asset_account;

  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency, owner_type, owner_id, is_control
  ) VALUES (
    '00000000-0000-4000-8000-000000000101', '2100.WALLET', 'Owner wallet liability',
    'liability', 'credit', 'NGN', 'user', '00000000-0000-4000-8000-000000000101', TRUE
  ) RETURNING id INTO liability_account;

  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency, owner_type, is_control
  ) VALUES (
    '00000000-0000-4000-8000-000000000102', '1100.CLEARING', 'Outsider clearing',
    'asset', 'debit', 'NGN', 'system', TRUE
  ) RETURNING id INTO outsider_account;

  entry_id := post_financial_journal(
    '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
    'wallets', 'schema-funding-1', 'schema-funding-0001', repeat('a', 64),
    '00000000-0000-4000-8000-000000009001', 'Schema wallet funding',
    '00000000-0000-4000-8000-000000000101',
    jsonb_build_array(
      jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
      jsonb_build_object('account_id', liability_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 10000)
    )
  );

  IF (SELECT count(*) FROM journal_lines WHERE journal_entry_id = entry_id) <> 2 THEN
    RAISE EXCEPTION 'balanced posting did not create two journal lines';
  END IF;
  IF (SELECT debit_total_minor FROM financial_account_balances WHERE account_id = asset_account) <> 10000
    OR (SELECT credit_total_minor FROM financial_account_balances WHERE account_id = liability_account) <> 10000 THEN
    RAISE EXCEPTION 'derived account balances do not match the journal';
  END IF;

  duplicate_id := post_financial_journal(
    '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
    'wallets', 'schema-funding-1', 'schema-funding-0001', repeat('a', 64),
    '00000000-0000-4000-8000-000000009001', 'Schema wallet funding',
    '00000000-0000-4000-8000-000000000101',
    jsonb_build_array(
      jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
      jsonb_build_object('account_id', liability_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 10000)
    )
  );
  IF duplicate_id <> entry_id OR (SELECT count(*) FROM journal_entries WHERE id = entry_id) <> 1 THEN
    RAISE EXCEPTION 'idempotent posting created a duplicate journal';
  END IF;

  BEGIN
    PERFORM post_financial_journal(
      '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
      'wallets', 'changed', 'schema-funding-0001', repeat('b', 64),
      '00000000-0000-4000-8000-000000009001', 'Changed request',
      '00000000-0000-4000-8000-000000000101',
      jsonb_build_array(
        jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
        jsonb_build_object('account_id', liability_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 10000)
      )
    );
    RAISE EXCEPTION 'changed idempotent request was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'changed idempotent request was accepted' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM post_financial_journal(
      '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
      'wallets', 'unbalanced', 'schema-unbalanced-0001', repeat('c', 64),
      '00000000-0000-4000-8000-000000009002', 'Unbalanced request',
      '00000000-0000-4000-8000-000000000101',
      jsonb_build_array(
        jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
        jsonb_build_object('account_id', liability_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 9999)
      )
    );
    RAISE EXCEPTION 'unbalanced journal was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'unbalanced journal was accepted' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM post_financial_journal(
      '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
      'wallets', 'cross-tenant', 'schema-cross-tenant-0001', repeat('d', 64),
      '00000000-0000-4000-8000-000000009003', 'Cross tenant request',
      '00000000-0000-4000-8000-000000000101',
      jsonb_build_array(
        jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
        jsonb_build_object('account_id', outsider_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 10000)
      )
    );
    RAISE EXCEPTION 'cross-tenant account was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant account was accepted' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE journal_lines SET amount_minor = 1 WHERE journal_entry_id = entry_id;
    RAISE EXCEPTION 'posted journal line was mutable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'posted journal line was mutable' THEN RAISE; END IF;
  END;

  UPDATE accounting_periods
  SET status = 'closed', closed_at = NOW(), closed_by = '00000000-0000-4000-8000-000000000101'
  WHERE organization_id = '00000000-0000-4000-8000-000000000101';
  duplicate_id := post_financial_journal(
    '00000000-0000-4000-8000-000000000101', 'NGN', DATE '2026-07-19',
    'wallets', 'schema-funding-1', 'schema-funding-0001', repeat('a', 64),
    '00000000-0000-4000-8000-000000009001', 'Schema wallet funding',
    '00000000-0000-4000-8000-000000000101',
    jsonb_build_array(
      jsonb_build_object('account_id', asset_account, 'line_number', 1, 'side', 'debit', 'amount_minor', 10000),
      jsonb_build_object('account_id', liability_account, 'line_number', 2, 'side', 'credit', 'amount_minor', 10000)
    )
  );
  IF duplicate_id <> entry_id OR (SELECT count(*) FROM journal_entries WHERE id = entry_id) <> 1 THEN
    RAISE EXCEPTION 'idempotent retry failed after its accounting period closed';
  END IF;
END $$;

GRANT SELECT ON financial_accounts, accounting_periods, journal_entries, journal_lines,
  financial_account_balances TO authenticated;
SET ROLE authenticated;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM journal_entries) <> 1 OR (SELECT count(*) FROM financial_accounts) <> 2 THEN
    RAISE EXCEPTION 'ledger owner cannot read its financial records';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM journal_entries) <> 0 OR (SELECT count(*) FROM financial_accounts) <> 1 THEN
    RAISE EXCEPTION 'financial records leaked across organizations';
  END IF;
END $$;
RESET ROLE;
