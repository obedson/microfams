-- Close the FC-08 cache-write bypass: application roles can set arbitrary custom
-- PostgreSQL settings, so a GUC is not an authorization boundary. The posting
-- engine now issues a transaction- and owner-scoped capability that application
-- roles cannot create or inspect.

CREATE TABLE IF NOT EXISTS wallet_cache_write_capabilities (
  backend_pid INTEGER NOT NULL,
  transaction_id BIGINT NOT NULL,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  owner_type TEXT NOT NULL CHECK (owner_type IN ('user', 'group')),
  owner_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (backend_pid, transaction_id, organization_id, owner_type, owner_id)
);

REVOKE ALL ON wallet_cache_write_capabilities FROM PUBLIC, anon, authenticated, service_role;
ALTER TABLE wallet_cache_write_capabilities ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION protect_cutover_wallet_cache() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_organization_id UUID;
  v_owner_type TEXT;
  v_owner_id UUID;
BEGIN
  v_organization_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.organization_id ELSE NEW.organization_id END;
  v_owner_type := CASE WHEN TG_TABLE_NAME = 'user_wallets' THEN 'user' ELSE 'group' END;
  v_owner_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;

  IF EXISTS (
    SELECT 1 FROM wallet_ledger_cutovers
    WHERE organization_id = v_organization_id AND status = 'active'
  ) AND NOT EXISTS (
    SELECT 1 FROM wallet_cache_write_capabilities
    WHERE backend_pid = pg_backend_pid()
      AND transaction_id = txid_current()
      AND organization_id = v_organization_id
      AND owner_type = v_owner_type
      AND owner_id = v_owner_id
  ) THEN
    RAISE EXCEPTION 'Wallet ledger cutover is active; balance cache writes require the posting engine';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE OR REPLACE FUNCTION sync_wallet_ledger_cache(
  p_organization_id UUID, p_owner_type TEXT, p_owner_id UUID, p_account_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance_minor BIGINT;
  v_backend_pid INTEGER := pg_backend_pid();
  v_transaction_id BIGINT := txid_current();
BEGIN
  IF p_owner_type NOT IN ('user', 'group') THEN
    RAISE EXCEPTION 'Unsupported wallet cache owner';
  END IF;
  v_balance_minor := wallet_account_balance_minor(p_account_id);
  IF v_balance_minor IS NULL OR v_balance_minor < 0 THEN
    RAISE EXCEPTION 'Wallet ledger balance cannot be negative';
  END IF;

  INSERT INTO wallet_cache_write_capabilities(
    backend_pid, transaction_id, organization_id, owner_type, owner_id
  ) VALUES (
    v_backend_pid, v_transaction_id, p_organization_id, p_owner_type, p_owner_id
  ) ON CONFLICT DO NOTHING;

  BEGIN
    IF p_owner_type = 'user' THEN
      UPDATE user_wallets
      SET balance = v_balance_minor::NUMERIC / 100, updated_at = NOW()
      WHERE organization_id = p_organization_id AND id = p_owner_id;
    ELSE
      UPDATE groups
      SET group_fund_balance = v_balance_minor::NUMERIC / 100, updated_at = NOW()
      WHERE organization_id = p_organization_id AND id = p_owner_id;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Wallet cache owner is unavailable'; END IF;
  EXCEPTION WHEN OTHERS THEN
    DELETE FROM wallet_cache_write_capabilities
    WHERE backend_pid = v_backend_pid AND transaction_id = v_transaction_id
      AND organization_id = p_organization_id AND owner_type = p_owner_type
      AND owner_id = p_owner_id;
    RAISE;
  END;

  DELETE FROM wallet_cache_write_capabilities
  WHERE backend_pid = v_backend_pid AND transaction_id = v_transaction_id
    AND organization_id = p_organization_id AND owner_type = p_owner_type
    AND owner_id = p_owner_id;
END;
$$;

REVOKE ALL ON FUNCTION protect_cutover_wallet_cache()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION sync_wallet_ledger_cache(UUID, TEXT, UUID, UUID)
  FROM PUBLIC, anon, authenticated, service_role;

DO $$
BEGIN
  IF has_function_privilege('service_role', 'sync_wallet_ledger_cache(uuid,text,uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role must not execute the wallet cache synchronization helper directly';
  END IF;
  IF has_table_privilege('service_role', 'wallet_cache_write_capabilities', 'SELECT')
    OR has_table_privilege('service_role', 'wallet_cache_write_capabilities', 'INSERT')
    OR has_table_privilege('service_role', 'wallet_cache_write_capabilities', 'UPDATE')
    OR has_table_privilege('service_role', 'wallet_cache_write_capabilities', 'DELETE') THEN
    RAISE EXCEPTION 'service_role must not access wallet cache write capabilities';
  END IF;
END $$;
