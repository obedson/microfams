-- FC-08 controlled opening-balance activation and reversal-only rollback.

CREATE TABLE IF NOT EXISTS wallet_ledger_cutovers (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id),
  migration_run_id UUID NOT NULL UNIQUE REFERENCES wallet_ledger_migration_runs(id),
  status TEXT NOT NULL CHECK (status IN ('active', 'rolled_back')),
  activated_by UUID NOT NULL REFERENCES users(id),
  activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  rolled_back_by UUID REFERENCES users(id),
  rolled_back_at TIMESTAMPTZ,
  CHECK (
    (status = 'active' AND rolled_back_by IS NULL AND rolled_back_at IS NULL)
    OR (status = 'rolled_back' AND rolled_back_by IS NOT NULL AND rolled_back_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS wallet_ledger_migration_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  migration_run_id UUID NOT NULL REFERENCES wallet_ledger_migration_runs(id),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  source_type TEXT NOT NULL CHECK (source_type IN ('wallet', 'group')),
  source_id UUID NOT NULL,
  financial_account_id UUID NOT NULL REFERENCES financial_accounts(id),
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
  opening_journal_entry_id UUID REFERENCES journal_entries(id),
  reversal_journal_entry_id UUID REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (migration_run_id, source_type, source_id),
  UNIQUE (opening_journal_entry_id),
  UNIQUE (reversal_journal_entry_id),
  CHECK (
    (amount_minor = 0 AND opening_journal_entry_id IS NULL)
    OR (amount_minor > 0 AND opening_journal_entry_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_wallet_ledger_items_run
  ON wallet_ledger_migration_items(migration_run_id, source_type);
CREATE UNIQUE INDEX IF NOT EXISTS uq_financial_accounts_owned_subledger
  ON financial_accounts(organization_id, owner_type, owner_id, currency)
  WHERE owner_id IS NOT NULL AND owner_type IN ('user', 'group');

CREATE OR REPLACE FUNCTION ensure_wallet_cutover_account(
  p_organization_id UUID,
  p_currency TEXT,
  p_owner_type TEXT,
  p_owner_id UUID,
  p_code TEXT,
  p_name TEXT,
  p_account_class TEXT,
  p_normal_side TEXT,
  p_created_by UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency,
    owner_type, owner_id, is_control, created_by
  ) VALUES (
    p_organization_id, p_code, p_name, p_account_class, p_normal_side, upper(p_currency),
    p_owner_type, p_owner_id, TRUE, p_created_by
  )
  ON CONFLICT (organization_id, code, currency) DO NOTHING
  RETURNING id INTO v_account_id;

  IF v_account_id IS NULL THEN
    SELECT id INTO v_account_id FROM financial_accounts
    WHERE organization_id = p_organization_id AND code = p_code AND currency = upper(p_currency)
      AND owner_type = p_owner_type AND owner_id IS NOT DISTINCT FROM p_owner_id
      AND account_class = p_account_class AND normal_side = p_normal_side;
  END IF;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Financial account code conflicts with a different identity';
  END IF;
  RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION protect_financial_journal() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'journal_entries' AND TG_OP = 'UPDATE'
    AND OLD.status = 'posted' AND NEW.status = 'reversed'
    AND (to_jsonb(OLD) - 'status') = (to_jsonb(NEW) - 'status')
    AND EXISTS (
      SELECT 1 FROM journal_entries reversal
      WHERE reversal.reversal_of_entry_id = OLD.id AND reversal.status = 'posted'
    ) THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'journal_entries' AND TG_OP = 'UPDATE'
    AND OLD.status = 'posted' AND NEW.status = 'posted'
    AND OLD.reversal_of_entry_id IS NULL AND NEW.reversal_of_entry_id IS NOT NULL
    AND (to_jsonb(OLD) - 'reversal_of_entry_id') = (to_jsonb(NEW) - 'reversal_of_entry_id')
    AND EXISTS (
      SELECT 1 FROM journal_entries original
      WHERE original.id = NEW.reversal_of_entry_id
        AND original.organization_id = NEW.organization_id
        AND original.currency = NEW.currency
        AND original.status = 'posted'
    ) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Posted financial journals are immutable';
END;
$$;

CREATE OR REPLACE FUNCTION reverse_financial_journal(
  p_original_entry_id UUID,
  p_idempotency_key TEXT,
  p_correlation_id UUID,
  p_actor_id UUID,
  p_description TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_original journal_entries;
  v_reversal_id UUID;
  v_request_hash TEXT;
  v_lines JSONB;
BEGIN
  SELECT * INTO v_original FROM journal_entries
  WHERE id = p_original_entry_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Original journal does not exist'; END IF;

  SELECT id INTO v_reversal_id FROM journal_entries
  WHERE reversal_of_entry_id = p_original_entry_id;
  IF v_reversal_id IS NOT NULL THEN RETURN v_reversal_id; END IF;
  IF v_original.status <> 'posted' THEN RAISE EXCEPTION 'Only a posted journal can be reversed'; END IF;
  IF length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Reversal idempotency key is invalid'; END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'account_id', account_id,
    'line_number', line_number,
    'side', CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
    'amount_minor', amount_minor,
    'memo', 'Reversal of ' || p_original_entry_id::TEXT
  ) ORDER BY line_number) INTO v_lines
  FROM journal_lines WHERE journal_entry_id = p_original_entry_id;
  v_request_hash := encode(digest(convert_to(concat_ws('|',
    p_original_entry_id::TEXT, p_idempotency_key, p_correlation_id::TEXT,
    p_actor_id::TEXT, p_description, v_lines::TEXT
  ), 'UTF8'), 'sha256'), 'hex');

  v_reversal_id := post_financial_journal(
    v_original.organization_id, v_original.currency, CURRENT_DATE,
    'financial.reversal', p_original_entry_id::TEXT, p_idempotency_key,
    v_request_hash, p_correlation_id, p_description, p_actor_id, v_lines
  );
  UPDATE journal_entries SET reversal_of_entry_id = p_original_entry_id
  WHERE id = v_reversal_id AND reversal_of_entry_id IS NULL;
  UPDATE journal_entries SET status = 'reversed' WHERE id = p_original_entry_id;
  RETURN v_reversal_id;
END;
$$;

CREATE OR REPLACE FUNCTION activate_wallet_ledger_cutover(
  p_organization_id UUID,
  p_migration_run_id UUID,
  p_actor_id UUID
) RETURNS wallet_ledger_cutovers
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_run wallet_ledger_migration_runs;
  v_cutover wallet_ledger_cutovers;
  v_currency TEXT;
  v_opening_account_id UUID;
  v_account_id UUID;
  v_journal_id UUID;
  v_amount_minor BIGINT;
  v_request_hash TEXT;
  v_wallet RECORD;
  v_group RECORD;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id
      AND status = 'active' AND role IN ('owner', 'admin', 'finance_manager')
  ) THEN RAISE EXCEPTION 'Actor is not authorized to activate wallet cutover'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('wallet-cutover:' || p_organization_id::TEXT, 0));
  SELECT * INTO v_cutover FROM wallet_ledger_cutovers WHERE organization_id = p_organization_id;
  IF FOUND THEN
    IF v_cutover.status = 'active' AND v_cutover.migration_run_id = p_migration_run_id THEN RETURN v_cutover; END IF;
    IF v_cutover.status = 'active' THEN RAISE EXCEPTION 'Organization already has an active wallet ledger cutover'; END IF;
    IF v_cutover.migration_run_id = p_migration_run_id THEN RAISE EXCEPTION 'A rolled-back readiness run cannot be reactivated'; END IF;
  END IF;

  SELECT * INTO v_run FROM wallet_ledger_migration_runs
  WHERE id = p_migration_run_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND OR v_run.status <> 'ready' OR v_run.anomaly_count <> 0 THEN
    RAISE EXCEPTION 'A successful readiness audit is required';
  END IF;
  IF p_migration_run_id <> (
    SELECT id FROM wallet_ledger_migration_runs
    WHERE organization_id = p_organization_id ORDER BY completed_at DESC, id DESC LIMIT 1
  ) THEN RAISE EXCEPTION 'Only the latest readiness audit may be activated'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM accounting_periods WHERE organization_id = p_organization_id
      AND status = 'open' AND CURRENT_DATE BETWEEN starts_on AND ends_on
  ) THEN RAISE EXCEPTION 'An open accounting period is required'; END IF;

  SELECT default_currency INTO v_currency FROM organizations
  WHERE id = p_organization_id AND status = 'active';
  IF v_currency IS NULL THEN RAISE EXCEPTION 'Organization is unavailable'; END IF;
  IF v_run.wallet_count <> (SELECT count(*) FROM user_wallets WHERE organization_id = p_organization_id)
    OR v_run.group_count <> (SELECT count(*) FROM groups WHERE organization_id = p_organization_id)
    OR v_run.legacy_transaction_count <> (SELECT count(*) FROM wallet_transactions WHERE organization_id = p_organization_id)
    OR v_run.wallet_total_minor IS DISTINCT FROM (
      SELECT COALESCE(sum(balance * 100), 0)::BIGINT FROM user_wallets WHERE organization_id = p_organization_id
    )
    OR v_run.group_total_minor IS DISTINCT FROM (
      SELECT COALESCE(sum(group_fund_balance * 100), 0)::BIGINT FROM groups WHERE organization_id = p_organization_id
    ) THEN RAISE EXCEPTION 'Wallet controls changed after the readiness audit'; END IF;

  v_opening_account_id := ensure_wallet_cutover_account(
    p_organization_id, v_currency, 'system', NULL, '3990.WALLET.OPENING',
    'Wallet migration opening balance', 'equity', 'credit', p_actor_id
  );

  FOR v_wallet IN
    SELECT id, user_id, balance FROM user_wallets WHERE organization_id = p_organization_id ORDER BY id
  LOOP
    v_amount_minor := (v_wallet.balance * 100)::BIGINT;
    v_account_id := ensure_wallet_cutover_account(
      p_organization_id, v_currency, 'user', v_wallet.user_id,
      '2100.WALLET.' || upper(substr(md5(v_wallet.id::TEXT), 1, 24)),
      'Individual wallet funds', 'liability', 'credit', p_actor_id
    );
    v_journal_id := NULL;
    IF v_amount_minor > 0 THEN
      v_request_hash := encode(digest(convert_to(concat_ws('|',
        p_organization_id::TEXT, p_migration_run_id::TEXT, 'wallet', v_wallet.id::TEXT,
        v_account_id::TEXT, v_amount_minor
      ), 'UTF8'), 'sha256'), 'hex');
      v_journal_id := post_financial_journal(
        p_organization_id, v_currency, CURRENT_DATE, 'migration.wallet_opening',
        v_wallet.id::TEXT, 'wallet:' || v_wallet.id::TEXT || ':' || p_migration_run_id::TEXT, v_request_hash,
        p_migration_run_id, 'Opening balance for tenant wallet', p_actor_id,
        jsonb_build_array(
          jsonb_build_object('account_id', v_opening_account_id, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor),
          jsonb_build_object('account_id', v_account_id, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor)
        )
      );
    END IF;
    INSERT INTO wallet_ledger_migration_items(
      migration_run_id, organization_id, source_type, source_id,
      financial_account_id, amount_minor, opening_journal_entry_id
    ) VALUES (
      p_migration_run_id, p_organization_id, 'wallet', v_wallet.id,
      v_account_id, v_amount_minor, v_journal_id
    );
  END LOOP;

  FOR v_group IN
    SELECT id, group_fund_balance FROM groups WHERE organization_id = p_organization_id ORDER BY id
  LOOP
    v_amount_minor := (v_group.group_fund_balance * 100)::BIGINT;
    v_account_id := ensure_wallet_cutover_account(
      p_organization_id, v_currency, 'group', v_group.id,
      '2200.GROUP.' || upper(substr(md5(v_group.id::TEXT), 1, 24)),
      'Group wallet funds', 'liability', 'credit', p_actor_id
    );
    v_journal_id := NULL;
    IF v_amount_minor > 0 THEN
      v_request_hash := encode(digest(convert_to(concat_ws('|',
        p_organization_id::TEXT, p_migration_run_id::TEXT, 'group', v_group.id::TEXT,
        v_account_id::TEXT, v_amount_minor
      ), 'UTF8'), 'sha256'), 'hex');
      v_journal_id := post_financial_journal(
        p_organization_id, v_currency, CURRENT_DATE, 'migration.wallet_opening',
        v_group.id::TEXT, 'group:' || v_group.id::TEXT || ':' || p_migration_run_id::TEXT, v_request_hash,
        p_migration_run_id, 'Opening balance for tenant group wallet', p_actor_id,
        jsonb_build_array(
          jsonb_build_object('account_id', v_opening_account_id, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor),
          jsonb_build_object('account_id', v_account_id, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor)
        )
      );
    END IF;
    INSERT INTO wallet_ledger_migration_items(
      migration_run_id, organization_id, source_type, source_id,
      financial_account_id, amount_minor, opening_journal_entry_id
    ) VALUES (
      p_migration_run_id, p_organization_id, 'group', v_group.id,
      v_account_id, v_amount_minor, v_journal_id
    );
  END LOOP;

  INSERT INTO wallet_ledger_cutovers(
    organization_id, migration_run_id, status, activated_by
  ) VALUES (p_organization_id, p_migration_run_id, 'active', p_actor_id)
  ON CONFLICT (organization_id) DO UPDATE SET
    migration_run_id = EXCLUDED.migration_run_id,
    status = 'active',
    activated_by = EXCLUDED.activated_by,
    activated_at = NOW(),
    rolled_back_by = NULL,
    rolled_back_at = NULL
  RETURNING * INTO v_cutover;
  RETURN v_cutover;
END;
$$;

CREATE OR REPLACE FUNCTION rollback_wallet_ledger_cutover(
  p_organization_id UUID,
  p_actor_id UUID
) RETURNS wallet_ledger_cutovers
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cutover wallet_ledger_cutovers;
  v_item RECORD;
  v_reversal_id UUID;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id
      AND status = 'active' AND role IN ('owner', 'admin', 'finance_manager')
  ) THEN RAISE EXCEPTION 'Actor is not authorized to roll back wallet cutover'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('wallet-cutover:' || p_organization_id::TEXT, 0));
  SELECT * INTO v_cutover FROM wallet_ledger_cutovers
  WHERE organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet ledger cutover does not exist'; END IF;
  IF v_cutover.status = 'rolled_back' THEN RETURN v_cutover; END IF;

  IF EXISTS (
    SELECT 1 FROM wallet_ledger_migration_items item
    JOIN journal_lines line ON line.account_id = item.financial_account_id
    JOIN journal_entries entry ON entry.id = line.journal_entry_id
    WHERE item.organization_id = p_organization_id
      AND item.migration_run_id = v_cutover.migration_run_id
      AND NOT EXISTS (
        SELECT 1
        FROM wallet_ledger_migration_items history
        WHERE history.organization_id = p_organization_id
          AND (
            history.opening_journal_entry_id = entry.id
            OR history.reversal_journal_entry_id = entry.id
          )
      )
  ) THEN RAISE EXCEPTION 'Wallet activity exists after cutover; rollback requires a controlled migration'; END IF;

  FOR v_item IN
    SELECT * FROM wallet_ledger_migration_items
    WHERE migration_run_id = v_cutover.migration_run_id AND opening_journal_entry_id IS NOT NULL
    ORDER BY created_at DESC, id DESC
  LOOP
    v_reversal_id := reverse_financial_journal(
      v_item.opening_journal_entry_id,
      'rollback:' || v_item.source_type || ':' || v_item.source_id::TEXT
        || ':' || v_cutover.migration_run_id::TEXT,
      v_cutover.migration_run_id,
      p_actor_id,
      'Rollback wallet opening balance'
    );
    UPDATE wallet_ledger_migration_items SET reversal_journal_entry_id = v_reversal_id
    WHERE id = v_item.id;
  END LOOP;

  UPDATE wallet_ledger_cutovers
  SET status = 'rolled_back', rolled_back_by = p_actor_id, rolled_back_at = NOW()
  WHERE organization_id = p_organization_id
  RETURNING * INTO v_cutover;
  RETURN v_cutover;
END;
$$;

CREATE OR REPLACE FUNCTION protect_cutover_wallet_cache() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_organization_id UUID;
BEGIN
  v_organization_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.organization_id ELSE NEW.organization_id END;
  IF EXISTS (
    SELECT 1 FROM wallet_ledger_cutovers
    WHERE organization_id = v_organization_id AND status = 'active'
  ) AND COALESCE(current_setting('microfams.wallet_posting_engine', TRUE), '') <> 'on' THEN
    RAISE EXCEPTION 'Wallet ledger cutover is active; balance cache writes require the posting engine';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS protect_cutover_user_wallet ON user_wallets;
CREATE TRIGGER protect_cutover_user_wallet
  BEFORE UPDATE OF balance OR DELETE ON user_wallets
  FOR EACH ROW EXECUTE FUNCTION protect_cutover_wallet_cache();
DROP TRIGGER IF EXISTS protect_cutover_group_wallet ON groups;
CREATE TRIGGER protect_cutover_group_wallet
  BEFORE UPDATE OF group_fund_balance OR DELETE ON groups
  FOR EACH ROW EXECUTE FUNCTION protect_cutover_wallet_cache();

REVOKE ALL ON wallet_ledger_cutovers, wallet_ledger_migration_items FROM anon, authenticated;
REVOKE ALL ON wallet_ledger_cutovers, wallet_ledger_migration_items FROM service_role;
GRANT SELECT ON wallet_ledger_cutovers, wallet_ledger_migration_items TO service_role;
REVOKE ALL ON FUNCTION ensure_wallet_cutover_account(UUID, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION reverse_financial_journal(UUID, TEXT, UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION activate_wallet_ledger_cutover(UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION rollback_wallet_ledger_cutover(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION activate_wallet_ledger_cutover(UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION rollback_wallet_ledger_cutover(UUID, UUID) TO service_role;

ALTER TABLE wallet_ledger_cutovers ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_ledger_migration_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON wallet_ledger_cutovers FOR SELECT
  USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON wallet_ledger_migration_items FOR SELECT
  USING (has_active_organization_membership(organization_id));
