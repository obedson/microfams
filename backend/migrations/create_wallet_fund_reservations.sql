-- FC-04 fund reservations and minor-unit wallet command adapters.

CREATE TABLE IF NOT EXISTS fund_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  wallet_id UUID NOT NULL REFERENCES user_wallets(id),
  wallet_account_id UUID NOT NULL REFERENCES financial_accounts(id),
  currency VARCHAR(3) NOT NULL DEFAULT 'NGN' CHECK (currency ~ '^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  purpose TEXT NOT NULL CHECK (purpose IN ('payout')),
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'consumed', 'released', 'expired')),
  source_domain TEXT NOT NULL CHECK (source_domain ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  source_record_id TEXT NOT NULL CHECK (length(source_record_id) BETWEEN 1 AND 160),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_journal_entry_id UUID REFERENCES journal_entries(id),
  restoration_journal_entry_id UUID REFERENCES journal_entries(id),
  consumed_at TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  expired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, source_domain, idempotency_key),
  UNIQUE (consumed_journal_entry_id),
  UNIQUE (restoration_journal_entry_id),
  CONSTRAINT fund_reservation_state_links CHECK (
    (state = 'active' AND consumed_journal_entry_id IS NULL AND restoration_journal_entry_id IS NULL)
    OR (state = 'consumed' AND consumed_journal_entry_id IS NOT NULL AND restoration_journal_entry_id IS NULL)
    OR (state = 'released' AND (
      (consumed_journal_entry_id IS NULL AND restoration_journal_entry_id IS NULL)
      OR (consumed_journal_entry_id IS NOT NULL AND restoration_journal_entry_id IS NOT NULL)
    ))
    OR (state = 'expired' AND consumed_journal_entry_id IS NULL AND restoration_journal_entry_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_fund_reservations_wallet_state
  ON fund_reservations(organization_id, wallet_id, state, expires_at);
CREATE INDEX IF NOT EXISTS idx_fund_reservations_expiry
  ON fund_reservations(expires_at) WHERE state = 'active';

CREATE OR REPLACE FUNCTION protect_fund_reservation() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF current_setting('microfams.reservation_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Fund reservations can only be changed by the reservation engine';
END;
$$;

DROP TRIGGER IF EXISTS fund_reservations_engine_only ON fund_reservations;
CREATE TRIGGER fund_reservations_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON fund_reservations
  FOR EACH ROW EXECUTE FUNCTION protect_fund_reservation();

ALTER TABLE withdrawal_requests ADD COLUMN IF NOT EXISTS reservation_id UUID REFERENCES fund_reservations(id);
ALTER TABLE withdrawal_requests ADD COLUMN IF NOT EXISTS amount_minor BIGINT;
ALTER TABLE withdrawal_requests ADD COLUMN IF NOT EXISTS fee_amount_minor BIGINT;
ALTER TABLE group_consensus_requests ADD COLUMN IF NOT EXISTS idempotency_key TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_group_consensus_idempotency'
      AND conrelid = 'group_consensus_requests'::regclass
  ) THEN
    ALTER TABLE group_consensus_requests ADD CONSTRAINT uq_group_consensus_idempotency
      UNIQUE (group_id, requested_by, idempotency_key);
  END IF;
END $$;

UPDATE withdrawal_requests
SET amount_minor = (amount * 100)::BIGINT,
    fee_amount_minor = (fee_amount * 100)::BIGINT
WHERE amount_minor IS NULL AND fee_amount_minor IS NULL
  AND amount * 100 = trunc(amount * 100)
  AND fee_amount * 100 = trunc(fee_amount * 100)
  AND amount * 100 <= 9223372036854775807
  AND fee_amount * 100 <= 9223372036854775807;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_withdrawal_request_reservation'
      AND conrelid = 'withdrawal_requests'::regclass
  ) THEN
    ALTER TABLE withdrawal_requests ADD CONSTRAINT uq_withdrawal_request_reservation UNIQUE (reservation_id);
  END IF;
END $$;

ALTER TABLE withdrawal_requests DROP CONSTRAINT IF EXISTS withdrawal_request_minor_amounts;
ALTER TABLE withdrawal_requests ADD CONSTRAINT withdrawal_request_minor_amounts CHECK (
  reservation_id IS NULL OR (amount_minor IS NOT NULL AND amount_minor > 0 AND fee_amount_minor IS NOT NULL AND fee_amount_minor >= 0)
);

CREATE OR REPLACE FUNCTION wallet_minor_to_major(p_amount_minor BIGINT) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT p_amount_minor::NUMERIC / 100 $$;

CREATE OR REPLACE FUNCTION wallet_balance_summary(p_wallet_id UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_wallet user_wallets;
  v_account_id UUID;
  v_ledger_minor BIGINT;
  v_reserved_minor BIGINT;
BEGIN
  SELECT * INTO v_wallet FROM user_wallets WHERE id = p_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;
  IF wallet_cutover_is_active(v_wallet.organization_id) THEN
    v_account_id := wallet_owned_account(v_wallet.organization_id, 'user', v_wallet.user_id);
    v_ledger_minor := wallet_account_balance_minor(v_account_id);
    SELECT COALESCE(sum(amount_minor), 0)::BIGINT INTO v_reserved_minor
    FROM fund_reservations
    WHERE organization_id = v_wallet.organization_id AND wallet_id = p_wallet_id
      AND state = 'active' AND expires_at > NOW();
  ELSE
    IF v_wallet.balance * 100 <> trunc(v_wallet.balance * 100)
      OR v_wallet.balance * 100 > 9223372036854775807 THEN
      RAISE EXCEPTION 'Legacy wallet balance cannot be represented in minor units';
    END IF;
    v_ledger_minor := (v_wallet.balance * 100)::BIGINT;
    v_reserved_minor := 0;
  END IF;
  RETURN jsonb_build_object(
    'currency', 'NGN',
    'ledgerBalanceMinor', v_ledger_minor,
    'pendingDebitsMinor', v_reserved_minor,
    'pendingCreditsMinor', 0,
    'availableBalanceMinor', v_ledger_minor - v_reserved_minor
  );
END;
$$;

CREATE OR REPLACE FUNCTION group_wallet_balance_summary(p_group_id UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_group groups;
  v_account_id UUID;
  v_ledger_minor BIGINT;
BEGIN
  SELECT * INTO v_group FROM groups WHERE id = p_group_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Group not found'; END IF;
  IF wallet_cutover_is_active(v_group.organization_id) THEN
    v_account_id := wallet_owned_account(v_group.organization_id, 'group', p_group_id);
    v_ledger_minor := wallet_account_balance_minor(v_account_id);
  ELSE
    IF v_group.group_fund_balance * 100 <> trunc(v_group.group_fund_balance * 100)
      OR v_group.group_fund_balance * 100 > 9223372036854775807 THEN
      RAISE EXCEPTION 'Legacy group balance cannot be represented in minor units';
    END IF;
    v_ledger_minor := (v_group.group_fund_balance * 100)::BIGINT;
  END IF;
  RETURN jsonb_build_object(
    'currency', 'NGN',
    'ledgerBalanceMinor', v_ledger_minor,
    'pendingDebitsMinor', 0,
    'pendingCreditsMinor', 0,
    'availableBalanceMinor', v_ledger_minor
  );
END;
$$;

CREATE OR REPLACE FUNCTION reserve_wallet_funds(
  p_wallet_id UUID,
  p_amount_minor BIGINT,
  p_source_record_id TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID,
  p_actor_id UUID,
  p_expires_at TIMESTAMPTZ
) RETURNS fund_reservations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_wallet user_wallets;
  v_account_id UUID;
  v_existing fund_reservations;
  v_result fund_reservations;
  v_hash TEXT;
  v_available BIGINT;
  v_previous_setting TEXT;
BEGIN
  IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN RAISE EXCEPTION 'Reservation amount must be positive minor units'; END IF;
  IF p_source_record_id IS NULL OR length(p_source_record_id) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Reservation source record is invalid'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Reservation idempotency key is invalid'; END IF;
  IF p_correlation_id IS NULL OR p_actor_id IS NULL THEN RAISE EXCEPTION 'Reservation correlation and actor are required'; END IF;
  IF p_expires_at <= NOW() OR p_expires_at > NOW() + INTERVAL '60 minutes' THEN
    RAISE EXCEPTION 'Reservation expiry must be within the next 60 minutes';
  END IF;

  SELECT * INTO v_wallet FROM user_wallets WHERE id = p_wallet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;
  IF NOT wallet_cutover_is_active(v_wallet.organization_id) THEN RAISE EXCEPTION 'Wallet ledger cutover is not active'; END IF;
  IF v_wallet.status <> 'ACTIVE' THEN RAISE EXCEPTION 'Wallet is not active'; END IF;
  IF v_wallet.user_id <> p_actor_id AND NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = v_wallet.organization_id AND user_id = p_actor_id
      AND status = 'active' AND role IN ('owner', 'admin', 'finance_manager')
  ) THEN RAISE EXCEPTION 'Actor cannot reserve this wallet'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    v_wallet.organization_id::TEXT, p_wallet_id::TEXT, p_amount_minor::TEXT,
    p_source_record_id, p_idempotency_key, p_correlation_id::TEXT, p_actor_id::TEXT,
    p_expires_at::TEXT
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM fund_reservations
  WHERE organization_id = v_wallet.organization_id
    AND source_domain = 'wallet.payout' AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'Reservation idempotency key reused with a different request'; END IF;
    RETURN v_existing;
  END IF;

  v_account_id := wallet_owned_account(v_wallet.organization_id, 'user', v_wallet.user_id);
  SELECT (summary->>'availableBalanceMinor')::BIGINT INTO v_available
  FROM (SELECT wallet_balance_summary(p_wallet_id) AS summary) value;
  IF v_available < p_amount_minor THEN RAISE EXCEPTION 'Insufficient available funds'; END IF;

  v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  INSERT INTO fund_reservations(
    organization_id, wallet_id, wallet_account_id, amount_minor, purpose, state,
    source_domain, source_record_id, idempotency_key, request_hash,
    correlation_id, actor_id, expires_at
  ) VALUES (
    v_wallet.organization_id, p_wallet_id, v_account_id, p_amount_minor, 'payout', 'active',
    'wallet.payout', p_source_record_id, p_idempotency_key, v_hash,
    p_correlation_id, p_actor_id, p_expires_at
  ) RETURNING * INTO v_result;
  PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION consume_wallet_reservation(
  p_reservation_id UUID, p_actor_id UUID
) RETURNS fund_reservations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation fund_reservations;
  v_wallet user_wallets;
  v_pending_account UUID;
  v_journal_id UUID;
  v_tx_id UUID;
  v_lines JSONB;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_reservation FROM fund_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.actor_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'Reservation actor does not match'; END IF;
  IF v_reservation.state = 'consumed' THEN RETURN v_reservation; END IF;
  IF v_reservation.state <> 'active' THEN RAISE EXCEPTION 'Reservation cannot be consumed from its current state'; END IF;
  IF v_reservation.expires_at <= NOW() THEN
    v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
    PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
    UPDATE fund_reservations SET state = 'expired', expired_at = NOW(), updated_at = NOW()
    WHERE id = p_reservation_id RETURNING * INTO v_reservation;
    PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
    RETURN v_reservation;
  END IF;
  SELECT * INTO v_wallet FROM user_wallets WHERE id = v_reservation.wallet_id FOR UPDATE;
  v_pending_account := ensure_wallet_system_account(
    v_reservation.organization_id,
    'WALLET.PENDING.' || upper(substr(md5(v_reservation.wallet_id::TEXT), 1, 24)),
    'Pending payout for wallet', 'liability', 'credit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_reservation.wallet_account_id, 'line_number', 1, 'side', 'debit', 'amount_minor', v_reservation.amount_minor, 'memo', 'Reserved wallet payout'),
    jsonb_build_object('account_id', v_pending_account, 'line_number', 2, 'side', 'credit', 'amount_minor', v_reservation.amount_minor, 'memo', 'Pending payout liability')
  );
  v_journal_id := post_wallet_journal(
    v_reservation.organization_id, 'wallet.reservation.consume', v_reservation.id::TEXT,
    'Consume wallet payout reservation', v_lines
  );
  INSERT INTO wallet_transactions(
    wallet_id, amount, amount_minor, type, direction, status, reference, metadata, journal_entry_id
  ) VALUES (
    v_reservation.wallet_id, wallet_minor_to_major(v_reservation.amount_minor), v_reservation.amount_minor,
    'WITHDRAWAL', 'DEBIT', 'SUCCESS', v_reservation.source_record_id,
    jsonb_build_object('reservation_id', v_reservation.id), v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_tx_id;
  v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  UPDATE fund_reservations
  SET state = 'consumed', consumed_journal_entry_id = v_journal_id,
      consumed_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id RETURNING * INTO v_reservation;
  PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM sync_wallet_ledger_cache(
    v_reservation.organization_id, 'user', v_reservation.wallet_id, v_reservation.wallet_account_id
  );
  RETURN v_reservation;
END;
$$;

CREATE OR REPLACE FUNCTION release_wallet_reservation(
  p_reservation_id UUID, p_actor_id UUID
) RETURNS fund_reservations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation fund_reservations;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_reservation FROM fund_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.actor_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'Reservation actor does not match'; END IF;
  IF v_reservation.state = 'released' THEN RETURN v_reservation; END IF;
  IF v_reservation.state <> 'active' THEN RAISE EXCEPTION 'Only an active reservation can be released without a journal'; END IF;
  v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  UPDATE fund_reservations SET state = 'released', released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id RETURNING * INTO v_reservation;
  PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_reservation;
END;
$$;

CREATE OR REPLACE FUNCTION restore_wallet_reservation(
  p_reservation_id UUID, p_actor_id UUID, p_reference TEXT
) RETURNS fund_reservations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation fund_reservations;
  v_wallet user_wallets;
  v_pending_account UUID;
  v_journal_id UUID;
  v_tx_id UUID;
  v_lines JSONB;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_reservation FROM fund_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.actor_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'Reservation actor does not match'; END IF;
  IF v_reservation.state = 'released' AND v_reservation.restoration_journal_entry_id IS NOT NULL THEN RETURN v_reservation; END IF;
  IF v_reservation.state <> 'consumed' THEN RAISE EXCEPTION 'Only a consumed reservation can be restored'; END IF;
  SELECT * INTO v_wallet FROM user_wallets WHERE id = v_reservation.wallet_id FOR UPDATE;
  v_pending_account := ensure_wallet_system_account(
    v_reservation.organization_id,
    'WALLET.PENDING.' || upper(substr(md5(v_reservation.wallet_id::TEXT), 1, 24)),
    'Pending payout for wallet', 'liability', 'credit'
  );
  IF wallet_account_balance_minor(v_pending_account) < v_reservation.amount_minor THEN
    RAISE EXCEPTION 'Pending payout is insufficient for reservation restoration';
  END IF;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_pending_account, 'line_number', 1, 'side', 'debit', 'amount_minor', v_reservation.amount_minor, 'memo', 'Failed payout restoration'),
    jsonb_build_object('account_id', v_reservation.wallet_account_id, 'line_number', 2, 'side', 'credit', 'amount_minor', v_reservation.amount_minor, 'memo', 'Restore wallet liability')
  );
  v_journal_id := post_wallet_journal(
    v_reservation.organization_id, 'wallet.reservation.restore', v_reservation.id::TEXT,
    'Restore failed wallet payout', v_lines
  );
  INSERT INTO wallet_transactions(
    wallet_id, amount, amount_minor, type, direction, status, reference, metadata, journal_entry_id
  ) VALUES (
    v_reservation.wallet_id, wallet_minor_to_major(v_reservation.amount_minor), v_reservation.amount_minor,
    'WITHDRAWAL', 'CREDIT', 'SUCCESS', p_reference,
    jsonb_build_object('reservation_id', v_reservation.id), v_journal_id
  ) ON CONFLICT (journal_entry_id, wallet_id, direction) WHERE journal_entry_id IS NOT NULL AND wallet_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_tx_id;
  v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  UPDATE fund_reservations
  SET state = 'released', restoration_journal_entry_id = v_journal_id,
      released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id RETURNING * INTO v_reservation;
  PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
  PERFORM sync_wallet_ledger_cache(
    v_reservation.organization_id, 'user', v_reservation.wallet_id, v_reservation.wallet_account_id
  );
  RETURN v_reservation;
END;
$$;

CREATE OR REPLACE FUNCTION expire_wallet_reservations(p_organization_id UUID) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
  v_previous_setting TEXT;
BEGIN
  v_previous_setting := current_setting('microfams.reservation_engine', TRUE);
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  UPDATE fund_reservations SET state = 'expired', expired_at = NOW(), updated_at = NOW()
  WHERE (p_organization_id IS NULL OR organization_id = p_organization_id)
    AND state = 'active' AND expires_at <= NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  PERFORM set_config('microfams.reservation_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION atomic_p2p_transfer_minor(
  p_sender_wallet_id UUID, p_recipient_wallet_id UUID, p_amount_minor BIGINT, p_reference VARCHAR
) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ SELECT atomic_p2p_transfer(p_sender_wallet_id, p_recipient_wallet_id, wallet_minor_to_major(p_amount_minor), p_reference) $$;

CREATE OR REPLACE FUNCTION atomic_group_credit_minor(
  p_group_id UUID, p_amount_minor BIGINT, p_reference VARCHAR
) RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ SELECT atomic_group_credit(p_group_id, wallet_minor_to_major(p_amount_minor), p_reference) $$;

CREATE OR REPLACE FUNCTION atomic_group_transfer_minor(
  p_group_id UUID, p_recipient_wallet_id UUID, p_amount_minor BIGINT,
  p_reference VARCHAR, p_approval_request_id UUID
) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ SELECT atomic_group_transfer(
  p_group_id, p_recipient_wallet_id, wallet_minor_to_major(p_amount_minor), p_reference, p_approval_request_id
) $$;

REVOKE ALL ON fund_reservations FROM anon, authenticated;
REVOKE ALL ON fund_reservations FROM service_role;
GRANT SELECT ON fund_reservations TO service_role;
ALTER TABLE fund_reservations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_read ON fund_reservations;
CREATE POLICY tenant_read ON fund_reservations FOR SELECT
  USING (has_active_organization_membership(organization_id));

REVOKE ALL ON FUNCTION wallet_minor_to_major(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION protect_fund_reservation() FROM PUBLIC;
REVOKE ALL ON FUNCTION wallet_balance_summary(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION group_wallet_balance_summary(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION reserve_wallet_funds(UUID, BIGINT, TEXT, TEXT, UUID, UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION consume_wallet_reservation(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION release_wallet_reservation(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION restore_wallet_reservation(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_wallet_reservations(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_p2p_transfer_minor(UUID, UUID, BIGINT, VARCHAR) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_group_credit_minor(UUID, BIGINT, VARCHAR) FROM PUBLIC;
REVOKE ALL ON FUNCTION atomic_group_transfer_minor(UUID, UUID, BIGINT, VARCHAR, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wallet_balance_summary(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION group_wallet_balance_summary(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION reserve_wallet_funds(UUID, BIGINT, TEXT, TEXT, UUID, UUID, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION consume_wallet_reservation(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION release_wallet_reservation(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION restore_wallet_reservation(UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION expire_wallet_reservations(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_p2p_transfer_minor(UUID, UUID, BIGINT, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_group_credit_minor(UUID, BIGINT, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_group_transfer_minor(UUID, UUID, BIGINT, VARCHAR, UUID) TO service_role;
