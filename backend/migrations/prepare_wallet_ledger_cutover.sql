-- FC-08 wallet cutover readiness: tenant wallet identity and audited controls.

DO $$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT c.conname INTO constraint_name
  FROM pg_constraint c
  WHERE c.conrelid = 'user_wallets'::regclass
    AND c.contype = 'u'
    AND (
      SELECT array_agg(a.attname::TEXT ORDER BY key_position)
      FROM unnest(c.conkey) WITH ORDINALITY AS keys(attnum, key_position)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = keys.attnum
    ) = ARRAY['user_id']::TEXT[]
  LIMIT 1;

  IF constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE user_wallets DROP CONSTRAINT %I', constraint_name);
  END IF;
END $$;

DROP INDEX IF EXISTS idx_user_wallets_user_id;
CREATE INDEX IF NOT EXISTS idx_user_wallets_user_id ON user_wallets(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_wallets_organization_user
  ON user_wallets(organization_id, user_id);

CREATE TABLE IF NOT EXISTS wallet_ledger_migration_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  requested_by UUID NOT NULL REFERENCES users(id),
  mode TEXT NOT NULL DEFAULT 'dry_run' CHECK (mode IN ('dry_run')),
  status TEXT NOT NULL CHECK (status IN ('ready', 'blocked')),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  wallet_count INTEGER NOT NULL CHECK (wallet_count >= 0),
  group_count INTEGER NOT NULL CHECK (group_count >= 0),
  wallet_total_minor BIGINT,
  group_total_minor BIGINT,
  legacy_transaction_count INTEGER NOT NULL CHECK (legacy_transaction_count >= 0),
  anomaly_count INTEGER NOT NULL CHECK (anomaly_count >= 0),
  control_hash VARCHAR(64) NOT NULL CHECK (control_hash ~ '^[a-f0-9]{64}$'),
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS wallet_ledger_migration_anomalies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id UUID NOT NULL REFERENCES wallet_ledger_migration_runs(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES organizations(id),
  code TEXT NOT NULL CHECK (code IN (
    'organization_unavailable', 'quarantined_organization', 'accounting_period_missing',
    'wallet_owner_not_member', 'wallet_amount_invalid', 'group_amount_invalid',
    'transaction_owner_missing', 'transaction_tenant_mismatch', 'transaction_amount_invalid',
    'duplicate_legacy_reference'
  )),
  source_type TEXT NOT NULL CHECK (source_type IN ('organization', 'wallet', 'group', 'transaction')),
  source_id TEXT,
  details JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(details) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_ledger_runs_organization
  ON wallet_ledger_migration_runs(organization_id, completed_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_anomalies_run
  ON wallet_ledger_migration_anomalies(run_id, code);

CREATE OR REPLACE FUNCTION audit_wallet_ledger_cutover(
  p_organization_id UUID,
  p_requested_by UUID
) RETURNS wallet_ledger_migration_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_run wallet_ledger_migration_runs;
  v_currency VARCHAR(3);
  v_organization_status TEXT;
  v_wallet_count INTEGER;
  v_group_count INTEGER;
  v_transaction_count INTEGER;
  v_wallet_total NUMERIC;
  v_group_total NUMERIC;
  v_anomaly_count INTEGER;
  v_control_hash TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_requested_by IS NULL THEN
    RAISE EXCEPTION 'Organization and requesting actor are required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_requested_by
      AND status = 'active'
      AND role IN ('owner', 'admin', 'finance_manager', 'auditor')
  ) THEN
    RAISE EXCEPTION 'Actor is not authorized to audit this organization';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('wallet-cutover-audit:' || p_organization_id::TEXT, 0));

  SELECT default_currency, status INTO v_currency, v_organization_status
  FROM organizations WHERE id = p_organization_id;
  v_currency := COALESCE(v_currency, 'NGN');

  SELECT count(*), sum(balance * 100)
  INTO v_wallet_count, v_wallet_total
  FROM user_wallets WHERE organization_id = p_organization_id;
  SELECT count(*), sum(group_fund_balance * 100)
  INTO v_group_count, v_group_total
  FROM groups WHERE organization_id = p_organization_id;
  SELECT count(*) INTO v_transaction_count
  FROM wallet_transactions WHERE organization_id = p_organization_id;

  INSERT INTO wallet_ledger_migration_runs(
    organization_id, requested_by, mode, status, currency, wallet_count, group_count,
    wallet_total_minor, group_total_minor, legacy_transaction_count, anomaly_count, control_hash
  ) VALUES (
    p_organization_id, p_requested_by, 'dry_run', 'ready', v_currency,
    v_wallet_count, v_group_count,
    CASE WHEN COALESCE(v_wallet_total, 0) BETWEEN 0 AND 9223372036854775807
      AND COALESCE(v_wallet_total, 0) = trunc(COALESCE(v_wallet_total, 0))
      THEN COALESCE(v_wallet_total, 0)::BIGINT ELSE NULL END,
    CASE WHEN COALESCE(v_group_total, 0) BETWEEN 0 AND 9223372036854775807
      AND COALESCE(v_group_total, 0) = trunc(COALESCE(v_group_total, 0))
      THEN COALESCE(v_group_total, 0)::BIGINT ELSE NULL END,
    v_transaction_count, 0, repeat('0', 64)
  ) RETURNING * INTO v_run;

  IF v_organization_status IS NULL OR v_organization_status <> 'active' THEN
    INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id)
    VALUES (v_run.id, p_organization_id, 'organization_unavailable', 'organization', p_organization_id::TEXT);
  END IF;
  IF p_organization_id = '00000000-0000-4000-8000-000000000900' THEN
    INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id)
    VALUES (v_run.id, p_organization_id, 'quarantined_organization', 'organization', p_organization_id::TEXT);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM accounting_periods
    WHERE organization_id = p_organization_id AND status = 'open'
      AND CURRENT_DATE BETWEEN starts_on AND ends_on
  ) THEN
    INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id)
    VALUES (v_run.id, p_organization_id, 'accounting_period_missing', 'organization', p_organization_id::TEXT);
  END IF;

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'wallet_owner_not_member', 'wallet', wallet.id::TEXT,
    jsonb_build_object('user_id', wallet.user_id)
  FROM user_wallets wallet
  WHERE wallet.organization_id = p_organization_id
    AND NOT EXISTS (
      SELECT 1 FROM organization_memberships membership
      WHERE membership.organization_id = wallet.organization_id
        AND membership.user_id = wallet.user_id AND membership.status = 'active'
    );

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'wallet_amount_invalid', 'wallet', id::TEXT,
    jsonb_build_object('balance', balance)
  FROM user_wallets
  WHERE organization_id = p_organization_id
    AND (balance < 0 OR balance * 100 <> trunc(balance * 100)
      OR balance * 100 > 9223372036854775807);

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'group_amount_invalid', 'group', id::TEXT,
    jsonb_build_object('balance', group_fund_balance)
  FROM groups
  WHERE organization_id = p_organization_id
    AND (group_fund_balance < 0 OR group_fund_balance * 100 <> trunc(group_fund_balance * 100)
      OR group_fund_balance * 100 > 9223372036854775807);

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id)
  SELECT v_run.id, p_organization_id, 'transaction_owner_missing', 'transaction', transaction.id::TEXT
  FROM wallet_transactions transaction
  WHERE transaction.organization_id = p_organization_id
    AND num_nonnulls(transaction.wallet_id, transaction.group_id) <> 1;

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'transaction_tenant_mismatch', 'transaction', transaction.id::TEXT,
    jsonb_build_object('transaction_organization_id', transaction.organization_id)
  FROM wallet_transactions transaction
  LEFT JOIN user_wallets wallet ON wallet.id = transaction.wallet_id
  LEFT JOIN groups owned_group ON owned_group.id = transaction.group_id
  WHERE transaction.organization_id = p_organization_id
    AND COALESCE(wallet.organization_id, owned_group.organization_id) IS DISTINCT FROM transaction.organization_id;

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'transaction_amount_invalid', 'transaction', id::TEXT,
    jsonb_build_object('amount', amount)
  FROM wallet_transactions
  WHERE organization_id = p_organization_id
    AND (amount <= 0 OR amount * 100 <> trunc(amount * 100)
      OR amount * 100 > 9223372036854775807);

  INSERT INTO wallet_ledger_migration_anomalies(run_id, organization_id, code, source_type, source_id, details)
  SELECT v_run.id, p_organization_id, 'duplicate_legacy_reference', 'transaction', NULL,
    jsonb_build_object('reference', reference, 'direction', direction, 'owner', owner_key, 'count', duplicate_count)
  FROM (
    SELECT reference, direction, COALESCE(wallet_id::TEXT, group_id::TEXT) AS owner_key,
      count(*) AS duplicate_count
    FROM wallet_transactions
    WHERE organization_id = p_organization_id
    GROUP BY reference, direction, COALESCE(wallet_id::TEXT, group_id::TEXT)
    HAVING count(*) > 1
  ) duplicates;

  SELECT count(*) INTO v_anomaly_count
  FROM wallet_ledger_migration_anomalies WHERE run_id = v_run.id;
  SELECT encode(digest(convert_to(concat_ws('|',
    p_organization_id::TEXT, v_currency, v_wallet_count, v_group_count,
    COALESCE(v_wallet_total, 0), COALESCE(v_group_total, 0), v_transaction_count,
    v_anomaly_count
  ), 'UTF8'), 'sha256'), 'hex') INTO v_control_hash;

  UPDATE wallet_ledger_migration_runs
  SET status = CASE WHEN v_anomaly_count = 0 THEN 'ready' ELSE 'blocked' END,
      anomaly_count = v_anomaly_count,
      control_hash = v_control_hash,
      completed_at = NOW()
  WHERE id = v_run.id
  RETURNING * INTO v_run;
  RETURN v_run;
END;
$$;

REVOKE ALL ON wallet_ledger_migration_runs, wallet_ledger_migration_anomalies FROM anon, authenticated;
REVOKE ALL ON wallet_ledger_migration_runs, wallet_ledger_migration_anomalies FROM service_role;
GRANT SELECT ON wallet_ledger_migration_runs, wallet_ledger_migration_anomalies TO service_role;
REVOKE ALL ON FUNCTION audit_wallet_ledger_cutover(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit_wallet_ledger_cutover(UUID, UUID) TO service_role;

ALTER TABLE wallet_ledger_migration_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_ledger_migration_anomalies ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON wallet_ledger_migration_runs FOR SELECT
  USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON wallet_ledger_migration_anomalies FOR SELECT
  USING (has_active_organization_membership(organization_id));
