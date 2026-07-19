-- FC-08 wallet posting engine. Active cutovers use the financial journal as
-- source of truth while retaining wallet_transactions as append-only evidence.

ALTER TABLE wallet_transactions
  ADD COLUMN IF NOT EXISTS amount_minor BIGINT,
  ADD COLUMN IF NOT EXISTS journal_entry_id UUID REFERENCES journal_entries(id);

UPDATE wallet_transactions
SET amount_minor = (amount * 100)::BIGINT
WHERE amount_minor IS NULL
  AND amount > 0
  AND amount * 100 = trunc(amount * 100)
  AND amount * 100 <= 9223372036854775807;

ALTER TABLE wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_journal_amount;
ALTER TABLE wallet_transactions ADD CONSTRAINT wallet_transactions_journal_amount
  CHECK (journal_entry_id IS NULL OR amount_minor IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS uq_wallet_tx_journal_wallet_direction
  ON wallet_transactions(journal_entry_id, wallet_id, direction)
  WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_wallet_tx_journal_group_direction
  ON wallet_transactions(journal_entry_id, group_id, direction)
  WHERE journal_entry_id IS NOT NULL AND group_id IS NOT NULL;

CREATE OR REPLACE FUNCTION protect_wallet_transaction_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'Wallet transaction evidence is append-only';
END;
$$;

DROP TRIGGER IF EXISTS wallet_transactions_append_only ON wallet_transactions;
CREATE TRIGGER wallet_transactions_append_only
  BEFORE UPDATE OR DELETE ON wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION protect_wallet_transaction_evidence();

CREATE OR REPLACE FUNCTION wallet_major_to_minor(p_amount NUMERIC) RETURNS BIGINT
LANGUAGE plpgsql IMMUTABLE SET search_path = public
AS $$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF p_amount * 100 <> trunc(p_amount * 100) THEN
    RAISE EXCEPTION 'Amount cannot contain fractions below one minor unit';
  END IF;
  IF p_amount * 100 > 9223372036854775807 THEN RAISE EXCEPTION 'Amount exceeds the supported range'; END IF;
  RETURN (p_amount * 100)::BIGINT;
END;
$$;

CREATE OR REPLACE FUNCTION wallet_reference_uuid(
  p_organization_id UUID, p_namespace TEXT, p_reference TEXT
) RETURNS UUID
LANGUAGE sql IMMUTABLE SET search_path = public
AS $$
  SELECT (
    substr(value, 1, 8) || '-' || substr(value, 9, 4) || '-' || substr(value, 13, 4)
    || '-' || substr(value, 17, 4) || '-' || substr(value, 21, 12)
  )::UUID
  FROM (SELECT md5(p_organization_id::TEXT || ':' || p_namespace || ':' || p_reference) AS value) hash;
$$;

CREATE OR REPLACE FUNCTION wallet_cutover_is_active(p_organization_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM wallet_ledger_cutovers
    WHERE organization_id = p_organization_id AND status = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION wallet_journal_exists(
  p_organization_id UUID, p_source_domain TEXT, p_reference TEXT
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM journal_entries
    WHERE organization_id = p_organization_id
      AND source_domain = p_source_domain
      AND idempotency_key = p_source_domain || ':' || p_reference
  );
$$;

CREATE OR REPLACE FUNCTION wallet_owned_account(
  p_organization_id UUID, p_owner_type TEXT, p_owner_id UUID
) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_account_id UUID;
BEGIN
  SELECT id INTO v_account_id FROM financial_accounts
  WHERE organization_id = p_organization_id AND currency = 'NGN'
    AND owner_type = p_owner_type AND owner_id = p_owner_id
    AND account_class = 'liability' AND normal_side = 'credit' AND status = 'active';
  IF v_account_id IS NULL THEN RAISE EXCEPTION 'Active wallet ledger account is unavailable'; END IF;
  RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION ensure_wallet_system_account(
  p_organization_id UUID, p_code TEXT, p_name TEXT, p_account_class TEXT, p_normal_side TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_account_id UUID;
BEGIN
  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency,
    owner_type, owner_id, is_control, status
  ) VALUES (
    p_organization_id, p_code, p_name, p_account_class, p_normal_side, 'NGN',
    'system', NULL, TRUE, 'active'
  ) ON CONFLICT (organization_id, code, currency) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_account_id;
  IF NOT EXISTS (
    SELECT 1 FROM financial_accounts
    WHERE id = v_account_id AND organization_id = p_organization_id
      AND code = p_code AND currency = 'NGN' AND owner_type = 'system' AND owner_id IS NULL
      AND account_class = p_account_class AND normal_side = p_normal_side AND status = 'active'
  ) THEN RAISE EXCEPTION 'Wallet system account conflicts with the approved chart mapping'; END IF;
  RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION wallet_account_balance_minor(p_account_id UUID) RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(balance.credit_total_minor - balance.debit_total_minor, 0)::BIGINT
  FROM financial_accounts account
  LEFT JOIN financial_account_balances balance ON balance.account_id = account.id
  WHERE account.id = p_account_id AND account.account_class = 'liability' AND account.normal_side = 'credit';
$$;

CREATE OR REPLACE FUNCTION sync_wallet_ledger_cache(
  p_organization_id UUID, p_owner_type TEXT, p_owner_id UUID, p_account_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_balance_minor BIGINT;
BEGIN
  v_balance_minor := wallet_account_balance_minor(p_account_id);
  IF v_balance_minor IS NULL OR v_balance_minor < 0 THEN RAISE EXCEPTION 'Wallet ledger balance cannot be negative'; END IF;
  PERFORM set_config('microfams.wallet_posting_engine', 'on', TRUE);
  IF p_owner_type = 'user' THEN
    UPDATE user_wallets SET balance = v_balance_minor::NUMERIC / 100, updated_at = NOW()
    WHERE organization_id = p_organization_id AND id = p_owner_id;
  ELSIF p_owner_type = 'group' THEN
    UPDATE groups SET group_fund_balance = v_balance_minor::NUMERIC / 100, updated_at = NOW()
    WHERE organization_id = p_organization_id AND id = p_owner_id;
  ELSE
    RAISE EXCEPTION 'Unsupported wallet cache owner';
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet cache owner is unavailable'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION post_wallet_journal(
  p_organization_id UUID,
  p_source_domain TEXT,
  p_reference TEXT,
  p_description TEXT,
  p_lines JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_hash TEXT;
BEGIN
  IF p_reference IS NULL OR length(p_reference) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Wallet reference is invalid';
  END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id::TEXT, p_source_domain, p_reference, p_description, p_lines::TEXT
  ), 'UTF8'), 'sha256'), 'hex');
  RETURN post_financial_journal(
    p_organization_id, 'NGN', CURRENT_DATE, p_source_domain, p_reference,
    p_source_domain || ':' || p_reference, v_hash,
    wallet_reference_uuid(p_organization_id, p_source_domain, p_reference),
    p_description, NULL, p_lines
  );
END;
$$;

CREATE OR REPLACE FUNCTION atomic_wallet_credit(
  p_wallet_id UUID, p_amount NUMERIC, p_type VARCHAR, p_reference VARCHAR,
  p_metadata JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_wallet user_wallets;
  v_amount_minor BIGINT;
  v_wallet_account UUID;
  v_counter_account UUID;
  v_journal_id UUID;
  v_tx_id UUID;
  v_lines JSONB;
BEGIN
  v_amount_minor := wallet_major_to_minor(p_amount);
  SELECT * INTO v_wallet FROM user_wallets WHERE id = p_wallet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;

  IF NOT wallet_cutover_is_active(v_wallet.organization_id) THEN
    INSERT INTO wallet_transactions(wallet_id, amount, amount_minor, type, direction, status, reference, metadata)
    VALUES (p_wallet_id, p_amount, v_amount_minor, p_type, 'CREDIT', 'SUCCESS', p_reference, p_metadata)
    RETURNING id INTO v_tx_id;
    UPDATE user_wallets SET balance = balance + p_amount, updated_at = NOW() WHERE id = p_wallet_id;
    RETURN v_tx_id;
  END IF;

  IF p_type NOT IN ('COLLECTION', 'WITHDRAWAL') THEN
    RAISE EXCEPTION 'Active cutover requires a balanced transfer command for this credit type';
  END IF;
  IF v_wallet.status <> 'ACTIVE' AND p_type <> 'WITHDRAWAL' THEN
    RAISE EXCEPTION 'Recipient wallet is not active';
  END IF;
  v_wallet_account := wallet_owned_account(v_wallet.organization_id, 'user', v_wallet.user_id);
  IF p_type = 'WITHDRAWAL' THEN
    v_counter_account := ensure_wallet_system_account(
      v_wallet.organization_id, 'WALLET.PENDING.' || upper(substr(md5(p_wallet_id::TEXT), 1, 24)),
      'Pending payout for wallet', 'liability', 'credit'
    );
  ELSE
    v_counter_account := ensure_wallet_system_account(
      v_wallet.organization_id, 'WALLET.PROVIDER_CLEARING', 'Wallet provider clearing', 'asset', 'debit'
    );
  END IF;
  IF p_type = 'WITHDRAWAL'
    AND NOT wallet_journal_exists(v_wallet.organization_id, 'wallet.credit', p_reference)
    AND wallet_account_balance_minor(v_counter_account) < v_amount_minor THEN
    RAISE EXCEPTION 'Pending payout is insufficient for restoration';
  END IF;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_counter_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor, 'memo', 'Wallet credit source'),
    jsonb_build_object('account_id', v_wallet_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor, 'memo', 'Wallet liability credit')
  );
  v_journal_id := post_wallet_journal(
    v_wallet.organization_id, 'wallet.credit', p_reference, 'Wallet credit', v_lines
  );
  INSERT INTO wallet_transactions(
    wallet_id, amount, amount_minor, type, direction, status, reference, metadata, journal_entry_id
  ) VALUES (
    p_wallet_id, p_amount, v_amount_minor, p_type, 'CREDIT', 'SUCCESS', p_reference, p_metadata, v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_tx_id;
  IF v_tx_id IS NULL THEN
    SELECT id INTO v_tx_id FROM wallet_transactions
    WHERE journal_entry_id = v_journal_id AND wallet_id = p_wallet_id AND direction = 'CREDIT';
  END IF;
  PERFORM sync_wallet_ledger_cache(v_wallet.organization_id, 'user', p_wallet_id, v_wallet_account);
  RETURN v_tx_id;
END;
$$;

CREATE OR REPLACE FUNCTION atomic_wallet_debit(
  p_wallet_id UUID, p_amount NUMERIC, p_type VARCHAR, p_reference VARCHAR,
  p_metadata JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_wallet user_wallets;
  v_amount_minor BIGINT;
  v_wallet_account UUID;
  v_counter_account UUID;
  v_journal_id UUID;
  v_tx_id UUID;
  v_lines JSONB;
BEGIN
  v_amount_minor := wallet_major_to_minor(p_amount);
  SELECT * INTO v_wallet FROM user_wallets WHERE id = p_wallet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;

  IF NOT wallet_cutover_is_active(v_wallet.organization_id) THEN
    IF v_wallet.balance < p_amount THEN RAISE EXCEPTION 'Insufficient funds'; END IF;
    INSERT INTO wallet_transactions(wallet_id, amount, amount_minor, type, direction, status, reference, metadata)
    VALUES (p_wallet_id, p_amount, v_amount_minor, p_type, 'DEBIT', 'SUCCESS', p_reference, p_metadata)
    RETURNING id INTO v_tx_id;
    UPDATE user_wallets SET balance = balance - p_amount, updated_at = NOW() WHERE id = p_wallet_id;
    RETURN v_tx_id;
  END IF;

  IF p_type <> 'WITHDRAWAL' THEN
    RAISE EXCEPTION 'Active cutover requires a balanced transfer command for this debit type';
  END IF;
  IF p_metadata->>'reason' = 'Grace period penalty settlement' THEN
    RAISE EXCEPTION 'Active cutover penalty debit requires an approved fee and revenue mapping';
  END IF;
  v_wallet_account := wallet_owned_account(v_wallet.organization_id, 'user', v_wallet.user_id);
  IF NOT wallet_journal_exists(v_wallet.organization_id, 'wallet.debit', p_reference)
    AND wallet_account_balance_minor(v_wallet_account) < v_amount_minor THEN RAISE EXCEPTION 'Insufficient funds'; END IF;
  v_counter_account := ensure_wallet_system_account(
    v_wallet.organization_id, 'WALLET.PENDING.' || upper(substr(md5(p_wallet_id::TEXT), 1, 24)),
    'Pending payout for wallet', 'liability', 'credit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_wallet_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor, 'memo', 'Wallet liability debit'),
    jsonb_build_object('account_id', v_counter_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor, 'memo', 'Pending payout credit')
  );
  v_journal_id := post_wallet_journal(
    v_wallet.organization_id, 'wallet.debit', p_reference, 'Wallet withdrawal reservation', v_lines
  );
  INSERT INTO wallet_transactions(
    wallet_id, amount, amount_minor, type, direction, status, reference, metadata, journal_entry_id
  ) VALUES (
    p_wallet_id, p_amount, v_amount_minor, p_type, 'DEBIT', 'SUCCESS', p_reference, p_metadata, v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_tx_id;
  IF v_tx_id IS NULL THEN
    SELECT id INTO v_tx_id FROM wallet_transactions
    WHERE journal_entry_id = v_journal_id AND wallet_id = p_wallet_id AND direction = 'DEBIT';
  END IF;
  PERFORM sync_wallet_ledger_cache(v_wallet.organization_id, 'user', p_wallet_id, v_wallet_account);
  RETURN v_tx_id;
END;
$$;

CREATE OR REPLACE FUNCTION atomic_p2p_transfer(
  p_sender_wallet_id UUID, p_recipient_wallet_id UUID, p_amount NUMERIC, p_reference VARCHAR
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sender user_wallets;
  v_recipient user_wallets;
  v_amount_minor BIGINT;
  v_sender_account UUID;
  v_recipient_account UUID;
  v_journal_id UUID;
  v_debit_tx_id UUID;
  v_credit_tx_id UUID;
  v_lines JSONB;
BEGIN
  IF p_sender_wallet_id = p_recipient_wallet_id THEN RAISE EXCEPTION 'Sender and recipient wallets must differ'; END IF;
  v_amount_minor := wallet_major_to_minor(p_amount);
  PERFORM id FROM user_wallets WHERE id IN (p_sender_wallet_id, p_recipient_wallet_id) ORDER BY id FOR UPDATE;
  SELECT * INTO v_sender FROM user_wallets WHERE id = p_sender_wallet_id;
  SELECT * INTO v_recipient FROM user_wallets WHERE id = p_recipient_wallet_id;
  IF v_sender.id IS NULL OR v_recipient.id IS NULL THEN RAISE EXCEPTION 'Wallet not found'; END IF;
  IF v_sender.organization_id <> v_recipient.organization_id THEN RAISE EXCEPTION 'Wallet transfer cannot cross organizations'; END IF;
  IF v_recipient.status <> 'ACTIVE' THEN RAISE EXCEPTION 'Recipient wallet is not active'; END IF;

  IF NOT wallet_cutover_is_active(v_sender.organization_id) THEN
    v_debit_tx_id := atomic_wallet_debit(p_sender_wallet_id, p_amount, 'P2P_TRANSFER', p_reference, jsonb_build_object('peer_wallet_id', p_recipient_wallet_id));
    v_credit_tx_id := atomic_wallet_credit(p_recipient_wallet_id, p_amount, 'P2P_TRANSFER', p_reference, jsonb_build_object('peer_wallet_id', p_sender_wallet_id));
    RETURN jsonb_build_object('debit_tx_id', v_debit_tx_id, 'credit_tx_id', v_credit_tx_id);
  END IF;

  v_sender_account := wallet_owned_account(v_sender.organization_id, 'user', v_sender.user_id);
  v_recipient_account := wallet_owned_account(v_sender.organization_id, 'user', v_recipient.user_id);
  IF NOT wallet_journal_exists(v_sender.organization_id, 'wallet.p2p', p_reference)
    AND wallet_account_balance_minor(v_sender_account) < v_amount_minor THEN RAISE EXCEPTION 'Insufficient funds'; END IF;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_sender_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor, 'memo', 'Sender wallet debit'),
    jsonb_build_object('account_id', v_recipient_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor, 'memo', 'Recipient wallet credit')
  );
  v_journal_id := post_wallet_journal(v_sender.organization_id, 'wallet.p2p', p_reference, 'Wallet P2P transfer', v_lines);
  INSERT INTO wallet_transactions(
    wallet_id, source_id, destination_id, amount, amount_minor, type, direction, status, reference, journal_entry_id
  ) VALUES (
    p_sender_wallet_id, p_sender_wallet_id, p_recipient_wallet_id, p_amount, v_amount_minor,
    'P2P_TRANSFER', 'DEBIT', 'SUCCESS', p_reference, v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_debit_tx_id;
  INSERT INTO wallet_transactions(
    wallet_id, source_id, destination_id, amount, amount_minor, type, direction, status, reference, journal_entry_id
  ) VALUES (
    p_recipient_wallet_id, p_sender_wallet_id, p_recipient_wallet_id, p_amount, v_amount_minor,
    'P2P_TRANSFER', 'CREDIT', 'SUCCESS', p_reference, v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_credit_tx_id;
  IF v_debit_tx_id IS NULL THEN SELECT id INTO v_debit_tx_id FROM wallet_transactions WHERE journal_entry_id = v_journal_id AND wallet_id = p_sender_wallet_id AND direction = 'DEBIT'; END IF;
  IF v_credit_tx_id IS NULL THEN SELECT id INTO v_credit_tx_id FROM wallet_transactions WHERE journal_entry_id = v_journal_id AND wallet_id = p_recipient_wallet_id AND direction = 'CREDIT'; END IF;
  PERFORM sync_wallet_ledger_cache(v_sender.organization_id, 'user', p_sender_wallet_id, v_sender_account);
  PERFORM sync_wallet_ledger_cache(v_sender.organization_id, 'user', p_recipient_wallet_id, v_recipient_account);
  RETURN jsonb_build_object('debit_tx_id', v_debit_tx_id, 'credit_tx_id', v_credit_tx_id, 'journal_entry_id', v_journal_id);
END;
$$;

CREATE OR REPLACE FUNCTION atomic_group_credit(
  p_group_id UUID, p_amount NUMERIC, p_reference VARCHAR
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_group groups;
  v_amount_minor BIGINT;
  v_group_account UUID;
  v_provider_account UUID;
  v_journal_id UUID;
  v_tx_id UUID;
  v_lines JSONB;
BEGIN
  v_amount_minor := wallet_major_to_minor(p_amount);
  SELECT * INTO v_group FROM groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Group not found'; END IF;
  IF NOT wallet_cutover_is_active(v_group.organization_id) THEN
    UPDATE groups SET group_fund_balance = group_fund_balance + p_amount, updated_at = NOW() WHERE id = p_group_id;
    INSERT INTO wallet_transactions(group_id, source_id, amount, amount_minor, type, direction, status, reference)
    VALUES (p_group_id, p_group_id, p_amount, v_amount_minor, 'COLLECTION', 'CREDIT', 'SUCCESS', p_reference)
    RETURNING id INTO v_tx_id;
    RETURN v_tx_id;
  END IF;
  v_group_account := wallet_owned_account(v_group.organization_id, 'group', p_group_id);
  v_provider_account := ensure_wallet_system_account(
    v_group.organization_id, 'WALLET.PROVIDER_CLEARING', 'Wallet provider clearing', 'asset', 'debit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_provider_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor, 'memo', 'Confirmed provider value'),
    jsonb_build_object('account_id', v_group_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor, 'memo', 'Group wallet liability credit')
  );
  v_journal_id := post_wallet_journal(v_group.organization_id, 'wallet.group_credit', p_reference, 'Confirmed group wallet funding', v_lines);
  INSERT INTO wallet_transactions(
    group_id, source_id, amount, amount_minor, type, direction, status, reference, journal_entry_id
  ) VALUES (
    p_group_id, p_group_id, p_amount, v_amount_minor, 'COLLECTION', 'CREDIT', 'SUCCESS', p_reference, v_journal_id
  ) ON CONFLICT (journal_entry_id, group_id, direction) WHERE journal_entry_id IS NOT NULL AND group_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_tx_id;
  IF v_tx_id IS NULL THEN SELECT id INTO v_tx_id FROM wallet_transactions WHERE journal_entry_id = v_journal_id AND group_id = p_group_id AND direction = 'CREDIT'; END IF;
  PERFORM sync_wallet_ledger_cache(v_group.organization_id, 'group', p_group_id, v_group_account);
  RETURN v_tx_id;
END;
$$;

CREATE OR REPLACE FUNCTION atomic_group_transfer(
  p_group_id UUID, p_recipient_wallet_id UUID, p_amount NUMERIC,
  p_reference VARCHAR, p_approval_request_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_group groups;
  v_recipient user_wallets;
  v_amount_minor BIGINT;
  v_group_account UUID;
  v_recipient_account UUID;
  v_journal_id UUID;
  v_debit_tx_id UUID;
  v_credit_tx_id UUID;
  v_lines JSONB;
BEGIN
  v_amount_minor := wallet_major_to_minor(p_amount);
  SELECT * INTO v_group FROM groups WHERE id = p_group_id FOR UPDATE;
  SELECT * INTO v_recipient FROM user_wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  IF v_group.id IS NULL THEN RAISE EXCEPTION 'Group not found'; END IF;
  IF v_recipient.id IS NULL THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;
  IF NOT wallet_cutover_is_active(v_group.organization_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM group_consensus_requests
      WHERE id = p_approval_request_id AND group_id = p_group_id
        AND status = 'APPROVED' AND amount = p_amount
        AND target_user_id = v_recipient.user_id
    ) THEN RAISE EXCEPTION 'Approved consensus request does not match transfer'; END IF;
    IF v_group.group_fund_balance < p_amount THEN RAISE EXCEPTION 'Insufficient group funds'; END IF;
    v_credit_tx_id := atomic_wallet_credit(
      p_recipient_wallet_id, p_amount, 'INTERNAL_TRANSFER', p_reference,
      jsonb_build_object('source_group_id', p_group_id)
    );
    UPDATE groups SET group_fund_balance = group_fund_balance - p_amount, updated_at = NOW() WHERE id = p_group_id;
    UPDATE group_consensus_requests SET status = 'EXECUTED', updated_at = NOW() WHERE id = p_approval_request_id;
    RETURN jsonb_build_object('credit_tx_id', v_credit_tx_id, 'group_id', p_group_id, 'status', 'EXECUTED');
  END IF;

  IF v_group.organization_id <> v_recipient.organization_id THEN RAISE EXCEPTION 'Group transfer cannot cross organizations'; END IF;
  IF v_recipient.status <> 'ACTIVE' THEN RAISE EXCEPTION 'Recipient wallet is not active'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_consensus_requests
    WHERE id = p_approval_request_id AND group_id = p_group_id
      AND status IN ('APPROVED', 'EXECUTED') AND amount = p_amount
      AND target_user_id = v_recipient.user_id
  ) THEN RAISE EXCEPTION 'Approved consensus request does not match transfer'; END IF;
  v_group_account := wallet_owned_account(v_group.organization_id, 'group', p_group_id);
  v_recipient_account := wallet_owned_account(v_group.organization_id, 'user', v_recipient.user_id);
  IF NOT wallet_journal_exists(v_group.organization_id, 'wallet.group_transfer', p_reference)
    AND wallet_account_balance_minor(v_group_account) < v_amount_minor THEN RAISE EXCEPTION 'Insufficient group funds'; END IF;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_group_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_amount_minor, 'memo', 'Group wallet liability debit'),
    jsonb_build_object('account_id', v_recipient_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_amount_minor, 'memo', 'Recipient wallet liability credit')
  );
  v_journal_id := post_wallet_journal(v_group.organization_id, 'wallet.group_transfer', p_reference, 'Group to user wallet transfer', v_lines);
  INSERT INTO wallet_transactions(
    group_id, source_id, destination_id, amount, amount_minor, type, direction, status, reference, journal_entry_id
  ) VALUES (
    p_group_id, p_group_id, p_recipient_wallet_id, p_amount, v_amount_minor,
    'INTERNAL_TRANSFER', 'DEBIT', 'SUCCESS', p_reference, v_journal_id
  ) ON CONFLICT (journal_entry_id, group_id, direction) WHERE journal_entry_id IS NOT NULL AND group_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_debit_tx_id;
  INSERT INTO wallet_transactions(
    wallet_id, source_id, destination_id, amount, amount_minor, type, direction, status, reference, journal_entry_id
  ) VALUES (
    p_recipient_wallet_id, p_group_id, p_recipient_wallet_id, p_amount, v_amount_minor,
    'INTERNAL_TRANSFER', 'CREDIT', 'SUCCESS', p_reference, v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_credit_tx_id;
  IF v_debit_tx_id IS NULL THEN SELECT id INTO v_debit_tx_id FROM wallet_transactions WHERE journal_entry_id = v_journal_id AND group_id = p_group_id AND direction = 'DEBIT'; END IF;
  IF v_credit_tx_id IS NULL THEN SELECT id INTO v_credit_tx_id FROM wallet_transactions WHERE journal_entry_id = v_journal_id AND wallet_id = p_recipient_wallet_id AND direction = 'CREDIT'; END IF;
  UPDATE group_consensus_requests SET status = 'EXECUTED', updated_at = NOW()
  WHERE id = p_approval_request_id AND status = 'APPROVED';
  PERFORM sync_wallet_ledger_cache(v_group.organization_id, 'group', p_group_id, v_group_account);
  PERFORM sync_wallet_ledger_cache(v_group.organization_id, 'user', p_recipient_wallet_id, v_recipient_account);
  RETURN jsonb_build_object(
    'debit_tx_id', v_debit_tx_id, 'credit_tx_id', v_credit_tx_id,
    'journal_entry_id', v_journal_id, 'group_id', p_group_id, 'status', 'EXECUTED'
  );
END;
$$;

CREATE OR REPLACE FUNCTION process_group_fund_payment(
  p_booking_id UUID, p_group_id UUID, p_amount NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_group groups;
BEGIN
  PERFORM wallet_major_to_minor(p_amount);
  SELECT * INTO v_group FROM groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Group not found'; END IF;
  IF wallet_cutover_is_active(v_group.organization_id) THEN
    RAISE EXCEPTION 'Active cutover booking payment requires the approved cross-organization settlement mapping';
  END IF;
  IF v_group.group_fund_balance < p_amount THEN RAISE EXCEPTION 'Insufficient group funds'; END IF;
  UPDATE groups SET group_fund_balance = group_fund_balance - p_amount, updated_at = NOW() WHERE id = p_group_id;
  UPDATE bookings SET payment_status = 'paid', status = 'confirmed', updated_at = NOW() WHERE id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
  RETURN jsonb_build_object('booking_id', p_booking_id, 'group_id', p_group_id, 'amount', p_amount, 'status', 'EXECUTED');
END;
$$;

REVOKE ALL ON FUNCTION protect_wallet_transaction_evidence() FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_major_to_minor(NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_reference_uuid(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_cutover_is_active(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_journal_exists(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_owned_account(UUID, TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION ensure_wallet_system_account(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_account_balance_minor(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION sync_wallet_ledger_cache(UUID, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION post_wallet_journal(UUID, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_wallet_credit(UUID, NUMERIC, VARCHAR, VARCHAR, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_wallet_debit(UUID, NUMERIC, VARCHAR, VARCHAR, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_p2p_transfer(UUID, UUID, NUMERIC, VARCHAR) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_group_credit(UUID, NUMERIC, VARCHAR) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_group_transfer(UUID, UUID, NUMERIC, VARCHAR, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION process_group_fund_payment(UUID, UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION atomic_wallet_credit(UUID, NUMERIC, VARCHAR, VARCHAR, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_wallet_debit(UUID, NUMERIC, VARCHAR, VARCHAR, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_p2p_transfer(UUID, UUID, NUMERIC, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_group_credit(UUID, NUMERIC, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_group_transfer(UUID, UUID, NUMERIC, VARCHAR, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION process_group_fund_payment(UUID, UUID, NUMERIC) TO service_role;
