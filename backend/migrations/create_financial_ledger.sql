-- Approved financial-core foundation: tenant accounts and immutable balanced journals.

CREATE TABLE IF NOT EXISTS financial_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  code TEXT NOT NULL CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 160),
  account_class TEXT NOT NULL CHECK (account_class IN ('asset', 'liability', 'equity', 'revenue', 'expense')),
  normal_side TEXT NOT NULL CHECK (normal_side IN ('debit', 'credit')),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  owner_type TEXT NOT NULL CHECK (owner_type IN (
    'organization', 'user', 'group', 'provider', 'escrow_contract', 'savings_contract',
    'loan_contract', 'investment_contract', 'system'
  )),
  owner_id UUID,
  is_control BOOLEAN NOT NULL DEFAULT FALSE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, code, currency),
  UNIQUE (id, organization_id, currency),
  CONSTRAINT financial_account_owner CHECK (
    (owner_type IN ('organization', 'system') AND owner_id IS NULL)
    OR (owner_type NOT IN ('organization', 'system') AND owner_id IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS accounting_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 100),
  starts_on DATE NOT NULL,
  ends_on DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'locked')),
  closed_at TIMESTAMPTZ,
  closed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (ends_on >= starts_on),
  CHECK ((status = 'open' AND closed_at IS NULL) OR status <> 'open'),
  UNIQUE (organization_id, starts_on, ends_on)
);

CREATE TABLE IF NOT EXISTS journal_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  effective_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'reversed')),
  source_domain TEXT NOT NULL CHECK (source_domain ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  source_record_id TEXT NOT NULL CHECK (length(source_record_id) BETWEEN 1 AND 160),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  description TEXT NOT NULL CHECK (length(btrim(description)) BETWEEN 2 AND 500),
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  reversal_of_entry_id UUID REFERENCES journal_entries(id),
  posted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, source_domain, idempotency_key),
  UNIQUE (reversal_of_entry_id),
  UNIQUE (id, organization_id, currency),
  CHECK (reversal_of_entry_id IS NULL OR reversal_of_entry_id <> id)
);

CREATE TABLE IF NOT EXISTS journal_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id UUID NOT NULL,
  organization_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL,
  account_id UUID NOT NULL,
  line_number INTEGER NOT NULL CHECK (line_number > 0),
  side TEXT NOT NULL CHECK (side IN ('debit', 'credit')),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  memo TEXT CHECK (memo IS NULL OR length(memo) <= 300),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (journal_entry_id, line_number),
  FOREIGN KEY (journal_entry_id, organization_id, currency)
    REFERENCES journal_entries(id, organization_id, currency),
  FOREIGN KEY (account_id, organization_id, currency)
    REFERENCES financial_accounts(id, organization_id, currency)
);

CREATE TABLE IF NOT EXISTS financial_account_balances (
  account_id UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL,
  debit_total_minor BIGINT NOT NULL DEFAULT 0 CHECK (debit_total_minor >= 0),
  credit_total_minor BIGINT NOT NULL DEFAULT 0 CHECK (credit_total_minor >= 0),
  net_debit_minor BIGINT GENERATED ALWAYS AS (debit_total_minor - credit_total_minor) STORED,
  version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (account_id, organization_id, currency)
    REFERENCES financial_accounts(id, organization_id, currency)
);

CREATE INDEX IF NOT EXISTS idx_financial_accounts_owner
  ON financial_accounts(organization_id, owner_type, owner_id);
CREATE INDEX IF NOT EXISTS idx_accounting_periods_lookup
  ON accounting_periods(organization_id, starts_on, ends_on, status);
CREATE INDEX IF NOT EXISTS idx_journal_entries_effective
  ON journal_entries(organization_id, effective_date, created_at);
CREATE INDEX IF NOT EXISTS idx_journal_entries_correlation
  ON journal_entries(organization_id, correlation_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_account
  ON journal_lines(organization_id, account_id, created_at);

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
  RAISE EXCEPTION 'Posted financial journals are immutable';
END;
$$;

DROP TRIGGER IF EXISTS journal_entries_immutable ON journal_entries;
CREATE TRIGGER journal_entries_immutable
  BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION protect_financial_journal();

DROP TRIGGER IF EXISTS journal_lines_immutable ON journal_lines;
CREATE TRIGGER journal_lines_immutable
  BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION protect_financial_journal();

CREATE OR REPLACE FUNCTION protect_financial_account_identity() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND EXISTS (SELECT 1 FROM journal_lines WHERE account_id = OLD.id) THEN
    RAISE EXCEPTION 'A used financial account cannot be deleted';
  END IF;
  IF TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM journal_lines WHERE account_id = OLD.id)
    AND (OLD.organization_id, OLD.code, OLD.account_class, OLD.normal_side, OLD.currency, OLD.owner_type, OLD.owner_id)
      IS DISTINCT FROM
        (NEW.organization_id, NEW.code, NEW.account_class, NEW.normal_side, NEW.currency, NEW.owner_type, NEW.owner_id) THEN
    RAISE EXCEPTION 'A used financial account identity cannot be changed';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS financial_account_identity_immutable ON financial_accounts;
CREATE TRIGGER financial_account_identity_immutable
  BEFORE UPDATE OR DELETE ON financial_accounts
  FOR EACH ROW EXECUTE FUNCTION protect_financial_account_identity();

CREATE OR REPLACE FUNCTION post_financial_journal(
  p_organization_id UUID,
  p_currency TEXT,
  p_effective_date DATE,
  p_source_domain TEXT,
  p_source_record_id TEXT,
  p_idempotency_key TEXT,
  p_request_hash TEXT,
  p_correlation_id UUID,
  p_description TEXT,
  p_actor_id UUID,
  p_lines JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_existing_id UUID;
  v_existing_hash TEXT;
  v_entry_id UUID;
  v_line_count INTEGER;
  v_debit_total NUMERIC;
  v_credit_total NUMERIC;
BEGIN
  p_currency := upper(p_currency);
  IF p_organization_id IS NULL THEN RAISE EXCEPTION 'Organization is required'; END IF;
  IF p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'Currency must be a three-letter ISO code'; END IF;
  IF p_effective_date IS NULL THEN RAISE EXCEPTION 'Effective date is required'; END IF;
  IF p_source_domain IS NULL OR p_source_domain !~ '^[a-z][a-z0-9_.-]{1,63}$' THEN RAISE EXCEPTION 'Source domain is invalid'; END IF;
  IF p_source_record_id IS NULL OR length(p_source_record_id) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Source record ID is invalid'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
  IF p_request_hash IS NULL OR p_request_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid request hash'; END IF;
  IF p_correlation_id IS NULL THEN RAISE EXCEPTION 'Correlation ID is required'; END IF;
  IF p_description IS NULL OR length(btrim(p_description)) NOT BETWEEN 2 AND 500 THEN RAISE EXCEPTION 'Description is invalid'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':' || p_source_domain || ':' || p_idempotency_key, 0
  ));
  SELECT id, request_hash INTO v_existing_id, v_existing_hash
  FROM journal_entries
  WHERE organization_id = p_organization_id
    AND source_domain = p_source_domain
    AND idempotency_key = p_idempotency_key;
  IF v_existing_id IS NOT NULL THEN
    IF v_existing_hash <> p_request_hash THEN
      RAISE EXCEPTION 'Idempotency key reused with a different request';
    END IF;
    RETURN v_existing_id;
  END IF;

  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
    RAISE EXCEPTION 'A journal requires at least two lines';
  END IF;
  IF p_actor_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Actor is not an active organization member';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM accounting_periods
    WHERE organization_id = p_organization_id AND status = 'open'
      AND p_effective_date BETWEEN starts_on AND ends_on
  ) THEN
    RAISE EXCEPTION 'No open accounting period contains the effective date';
  END IF;

  SELECT count(*),
    COALESCE(sum(amount_minor) FILTER (WHERE side = 'debit'), 0),
    COALESCE(sum(amount_minor) FILTER (WHERE side = 'credit'), 0)
  INTO v_line_count, v_debit_total, v_credit_total
  FROM jsonb_to_recordset(p_lines)
    AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT);

  IF v_line_count < 2 OR v_debit_total <> v_credit_total OR v_debit_total <= 0 THEN
    RAISE EXCEPTION 'Journal debits and credits must be positive and balanced';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_lines)
      AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT)
    WHERE account_id IS NULL OR line_number IS NULL OR line_number <= 0
      OR side NOT IN ('debit', 'credit') OR amount_minor IS NULL OR amount_minor <= 0
  ) THEN
    RAISE EXCEPTION 'Journal contains an invalid line';
  END IF;
  IF EXISTS (
    SELECT line_number FROM jsonb_to_recordset(p_lines)
      AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT)
    GROUP BY line_number HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Journal line numbers must be unique';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_lines)
      AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT)
    LEFT JOIN financial_accounts account
      ON account.id = line.account_id
      AND account.organization_id = p_organization_id
      AND account.currency = p_currency
      AND account.status = 'active'
    WHERE account.id IS NULL
  ) THEN
    RAISE EXCEPTION 'Journal account is unavailable in the organization and currency';
  END IF;

  INSERT INTO journal_entries(
    organization_id, currency, effective_date, source_domain, source_record_id,
    idempotency_key, request_hash, correlation_id, description, actor_id
  ) VALUES (
    p_organization_id, p_currency, p_effective_date, p_source_domain, p_source_record_id,
    p_idempotency_key, p_request_hash, p_correlation_id, p_description, p_actor_id
  ) RETURNING id INTO v_entry_id;

  INSERT INTO journal_lines(
    journal_entry_id, organization_id, currency, account_id, line_number, side, amount_minor, memo
  )
  SELECT v_entry_id, p_organization_id, p_currency,
    line.account_id, line.line_number, line.side, line.amount_minor, line.memo
  FROM jsonb_to_recordset(p_lines)
    AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT);

  INSERT INTO financial_account_balances(account_id, organization_id, currency)
  SELECT DISTINCT line.account_id, p_organization_id, p_currency
  FROM jsonb_to_recordset(p_lines)
    AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT)
  ON CONFLICT (account_id) DO NOTHING;

  WITH movement AS (
    SELECT line.account_id,
      COALESCE(sum(line.amount_minor) FILTER (WHERE line.side = 'debit'), 0)::BIGINT AS debits,
      COALESCE(sum(line.amount_minor) FILTER (WHERE line.side = 'credit'), 0)::BIGINT AS credits
    FROM jsonb_to_recordset(p_lines)
      AS line(account_id UUID, line_number INTEGER, side TEXT, amount_minor BIGINT, memo TEXT)
    GROUP BY line.account_id
  )
  UPDATE financial_account_balances balance
  SET debit_total_minor = balance.debit_total_minor + movement.debits,
      credit_total_minor = balance.credit_total_minor + movement.credits,
      version = balance.version + 1,
      updated_at = NOW()
  FROM movement WHERE balance.account_id = movement.account_id;

  RETURN v_entry_id;
END;
$$;

REVOKE ALL ON financial_accounts, accounting_periods, journal_entries, journal_lines,
  financial_account_balances FROM anon, authenticated;
REVOKE ALL ON journal_entries, journal_lines, financial_account_balances FROM service_role;
GRANT SELECT, INSERT, UPDATE ON financial_accounts, accounting_periods TO service_role;
GRANT SELECT ON journal_entries, journal_lines, financial_account_balances TO service_role;
REVOKE ALL ON FUNCTION post_financial_journal(UUID, TEXT, DATE, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION post_financial_journal(UUID, TEXT, DATE, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID, JSONB) TO service_role;

ALTER TABLE financial_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_account_balances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_read ON financial_accounts;
DROP POLICY IF EXISTS tenant_read ON accounting_periods;
DROP POLICY IF EXISTS tenant_read ON journal_entries;
DROP POLICY IF EXISTS tenant_read ON journal_lines;
DROP POLICY IF EXISTS tenant_read ON financial_account_balances;
CREATE POLICY tenant_read ON financial_accounts FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON accounting_periods FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON journal_entries FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON journal_lines FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON financial_account_balances FOR SELECT USING (has_active_organization_membership(organization_id));
