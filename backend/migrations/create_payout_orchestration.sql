-- FC-05/FC-06 provider-neutral payout orchestration and reconciliation.

CREATE TABLE IF NOT EXISTS payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  withdrawal_request_id UUID NOT NULL UNIQUE REFERENCES withdrawal_requests(id),
  reservation_id UUID NOT NULL UNIQUE REFERENCES fund_reservations(id),
  internal_reference TEXT NOT NULL CHECK (length(internal_reference) BETWEEN 8 AND 160),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_reference TEXT,
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  fee_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (fee_amount_minor >= 0),
  beneficiary_fingerprint VARCHAR(64) NOT NULL CHECK (beneficiary_fingerprint ~ '^[a-f0-9]{64}$'),
  beneficiary_masked TEXT NOT NULL CHECK (length(beneficiary_masked) BETWEEN 4 AND 40),
  state TEXT NOT NULL DEFAULT 'reserved' CHECK (state IN (
    'created', 'reserved', 'submitted', 'processing', 'succeeded', 'failed', 'reversed', 'cancelled'
  )),
  correlation_id UUID NOT NULL,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  success_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  failure_code TEXT,
  failure_reason TEXT,
  submitted_at TIMESTAMPTZ,
  terminal_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, internal_reference),
  UNIQUE (organization_id, idempotency_key),
  CONSTRAINT payout_terminal_shape CHECK (
    (state = 'succeeded' AND success_journal_entry_id IS NOT NULL AND terminal_at IS NOT NULL)
    OR (state IN ('failed', 'reversed', 'cancelled') AND terminal_at IS NOT NULL)
    OR (state NOT IN ('succeeded', 'failed', 'reversed', 'cancelled') AND terminal_at IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_payout_provider_reference
  ON payouts(provider_name, provider_environment, provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_payouts_service_queue
  ON payouts(provider_name, provider_environment, state, updated_at)
  WHERE state IN ('submitted', 'processing');

CREATE TABLE IF NOT EXISTS payout_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payout_id UUID NOT NULL REFERENCES payouts(id),
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL CHECK (state IN ('started', 'accepted', 'unknown', 'failed')),
  provider_reference TEXT,
  failure_code TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  UNIQUE (payout_id, attempt_number),
  UNIQUE (payout_id, request_hash)
);

CREATE TABLE IF NOT EXISTS provider_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payout_id UUID REFERENCES payouts(id),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_event_id TEXT,
  event_type TEXT NOT NULL CHECK (length(event_type) BETWEEN 2 AND 80),
  raw_event_hash VARCHAR(64) NOT NULL CHECK (raw_event_hash ~ '^[a-f0-9]{64}$'),
  signature_verified BOOLEAN NOT NULL CHECK (signature_verified),
  normalized_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  processing_state TEXT NOT NULL DEFAULT 'received' CHECK (processing_state IN ('received', 'processed', 'rejected')),
  rejection_reason TEXT,
  occurred_at TIMESTAMPTZ,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  UNIQUE (provider_name, provider_environment, raw_event_hash)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_provider_event_identifier
  ON provider_events(provider_name, provider_environment, provider_event_id)
  WHERE provider_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_provider_events_processing
  ON provider_events(processing_state, received_at);

CREATE TABLE IF NOT EXISTS reconciliation_configurations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  date_window_hours INTEGER NOT NULL DEFAULT 72 CHECK (date_window_hours BETWEEN 1 AND 720),
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  certification_status TEXT NOT NULL DEFAULT 'uncertified' CHECK (certification_status IN ('uncertified', 'certified', 'suspended')),
  certified_at TIMESTAMPTZ,
  certified_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, provider_name, provider_environment, currency),
  CHECK ((certification_status = 'certified') = (certified_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS reconciliation_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  configuration_id UUID NOT NULL REFERENCES reconciliation_configurations(id),
  source_hash VARCHAR(64) NOT NULL CHECK (source_hash ~ '^[a-f0-9]{64}$'),
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'running' CHECK (state IN ('running', 'completed', 'failed')),
  opening_balance_minor BIGINT NOT NULL DEFAULT 0,
  movement_minor BIGINT NOT NULL DEFAULT 0,
  closing_balance_minor BIGINT NOT NULL DEFAULT 0,
  provider_balance_minor BIGINT NOT NULL DEFAULT 0,
  matched_value_minor BIGINT NOT NULL DEFAULT 0 CHECK (matched_value_minor >= 0),
  unexplained_variance_minor BIGINT NOT NULL DEFAULT 0,
  started_by UUID REFERENCES users(id) ON DELETE SET NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  UNIQUE (configuration_id, source_hash),
  CHECK (period_end >= period_start)
);

CREATE TABLE IF NOT EXISTS reconciliation_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  run_id UUID NOT NULL REFERENCES reconciliation_runs(id),
  payout_id UUID REFERENCES payouts(id),
  provider_reference TEXT NOT NULL,
  internal_reference TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound')),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  occurred_at TIMESTAMPTZ NOT NULL,
  source_item_hash VARCHAR(64) NOT NULL CHECK (source_item_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL CHECK (state IN ('unmatched', 'matched', 'mismatch', 'duplicate', 'late', 'investigating', 'resolved')),
  mismatch_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (run_id, source_item_hash)
);

CREATE TABLE IF NOT EXISTS reconciliation_exceptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  run_id UUID NOT NULL REFERENCES reconciliation_runs(id),
  item_id UUID NOT NULL UNIQUE REFERENCES reconciliation_items(id),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'investigating', 'resolved')),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
  resolution_reason TEXT,
  evidence_reference TEXT,
  compensating_journal_entry_id UUID REFERENCES journal_entries(id),
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  CHECK (
    (state = 'resolved' AND resolution_reason IS NOT NULL AND evidence_reference IS NOT NULL AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)
    OR state <> 'resolved'
  )
);

CREATE OR REPLACE FUNCTION protect_payout_engine_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF current_setting('microfams.payout_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Payout records can only be changed by the payout engine';
END;
$$;

DROP TRIGGER IF EXISTS payouts_engine_only ON payouts;
CREATE TRIGGER payouts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payouts
  FOR EACH ROW EXECUTE FUNCTION protect_payout_engine_records();
DROP TRIGGER IF EXISTS payout_attempts_engine_only ON payout_attempts;
CREATE TRIGGER payout_attempts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payout_attempts
  FOR EACH ROW EXECUTE FUNCTION protect_payout_engine_records();
DROP TRIGGER IF EXISTS provider_events_engine_only ON provider_events;
CREATE TRIGGER provider_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON provider_events
  FOR EACH ROW EXECUTE FUNCTION protect_payout_engine_records();

CREATE OR REPLACE FUNCTION payout_transition_allowed(p_from TEXT, p_to TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT CASE p_from
  WHEN 'created' THEN p_to IN ('reserved', 'cancelled')
  WHEN 'reserved' THEN p_to IN ('submitted', 'processing', 'failed', 'cancelled')
  WHEN 'submitted' THEN p_to IN ('processing', 'succeeded', 'failed')
  WHEN 'processing' THEN p_to IN ('succeeded', 'failed')
  WHEN 'succeeded' THEN p_to = 'reversed'
  ELSE FALSE
END $$;

CREATE OR REPLACE FUNCTION create_wallet_payout(
  p_withdrawal_request_id UUID,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_beneficiary_fingerprint TEXT,
  p_beneficiary_masked TEXT,
  p_correlation_id UUID,
  p_actor_id UUID
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_withdrawal withdrawal_requests;
  v_reservation fund_reservations;
  v_existing payouts;
  v_result payouts;
  v_hash TEXT;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_withdrawal FROM withdrawal_requests WHERE id = p_withdrawal_request_id FOR UPDATE;
  IF NOT FOUND OR v_withdrawal.organization_id IS NULL THEN RAISE EXCEPTION 'Tenant withdrawal request is unavailable'; END IF;
  IF v_withdrawal.status <> 'PENDING' OR v_withdrawal.reservation_id IS NULL THEN RAISE EXCEPTION 'Withdrawal is not ready for payout'; END IF;
  SELECT * INTO v_reservation FROM fund_reservations WHERE id = v_withdrawal.reservation_id FOR UPDATE;
  IF NOT FOUND OR v_reservation.state <> 'consumed' THEN RAISE EXCEPTION 'Withdrawal reservation is not consumed'; END IF;
  IF v_reservation.organization_id <> v_withdrawal.organization_id OR v_reservation.wallet_id <> v_withdrawal.wallet_id THEN
    RAISE EXCEPTION 'Withdrawal reservation ownership mismatch';
  END IF;
  IF p_provider_name IS NULL OR p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$' THEN RAISE EXCEPTION 'Provider name is invalid'; END IF;
  IF p_provider_environment NOT IN ('deterministic', 'sandbox', 'live') THEN RAISE EXCEPTION 'Provider environment is invalid'; END IF;
  IF p_beneficiary_fingerprint !~ '^[a-f0-9]{64}$' OR length(p_beneficiary_masked) NOT BETWEEN 4 AND 40 THEN
    RAISE EXCEPTION 'Beneficiary identity is invalid';
  END IF;
  IF p_correlation_id IS NULL OR p_actor_id IS NULL THEN RAISE EXCEPTION 'Payout correlation and actor are required'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    v_withdrawal.organization_id::TEXT, v_withdrawal.id::TEXT, v_withdrawal.internal_ref,
    v_withdrawal.amount_minor::TEXT, v_withdrawal.fee_amount_minor::TEXT,
    p_provider_name, p_provider_environment, p_beneficiary_fingerprint, p_correlation_id::TEXT, p_actor_id::TEXT
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM payouts WHERE withdrawal_request_id = v_withdrawal.id;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'Payout replay changed the original request'; END IF;
    RETURN v_existing;
  END IF;

  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  INSERT INTO payouts(
    organization_id, withdrawal_request_id, reservation_id, internal_reference,
    idempotency_key, request_hash, provider_name, provider_environment, currency,
    amount_minor, fee_amount_minor, beneficiary_fingerprint, beneficiary_masked,
    state, correlation_id, actor_id
  ) VALUES (
    v_withdrawal.organization_id, v_withdrawal.id, v_reservation.id, v_withdrawal.internal_ref,
    v_reservation.idempotency_key, v_hash, p_provider_name, p_provider_environment, 'NGN',
    v_withdrawal.amount_minor, v_withdrawal.fee_amount_minor, p_beneficiary_fingerprint,
    p_beneficiary_masked, 'reserved', p_correlation_id, p_actor_id
  ) RETURNING * INTO v_result;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION mark_payout_submitted(
  p_payout_id UUID, p_request_hash TEXT, p_provider_reference TEXT, p_processing BOOLEAN DEFAULT FALSE
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_attempt INTEGER;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payout not found'; END IF;
  IF v_payout.state IN ('submitted', 'processing')
    AND (p_provider_reference IS NULL OR v_payout.provider_reference = p_provider_reference) THEN
    RETURN v_payout;
  END IF;
  IF NOT payout_transition_allowed(v_payout.state, CASE WHEN p_processing THEN 'processing' ELSE 'submitted' END) THEN
    RAISE EXCEPTION 'Payout transition is not allowed';
  END IF;
  SELECT COALESCE(max(attempt_number), 0) + 1 INTO v_attempt FROM payout_attempts WHERE payout_id = p_payout_id;
  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  INSERT INTO payout_attempts(
    organization_id, payout_id, attempt_number, request_hash, state, provider_reference, completed_at
  ) VALUES (
    v_payout.organization_id, v_payout.id, v_attempt, p_request_hash,
    CASE WHEN p_processing THEN 'unknown' ELSE 'accepted' END, p_provider_reference, NOW()
  );
  UPDATE payouts SET
    state = CASE WHEN p_processing THEN 'processing' ELSE 'submitted' END,
    provider_reference = COALESCE(p_provider_reference, provider_reference),
    submitted_at = COALESCE(submitted_at, NOW()), updated_at = NOW()
  WHERE id = p_payout_id RETURNING * INTO v_payout;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION succeed_wallet_payout(
  p_payout_id UUID, p_provider_reference TEXT, p_amount_minor BIGINT, p_currency TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_reservation fund_reservations;
  v_pending_account UUID;
  v_provider_account UUID;
  v_journal_id UUID;
  v_lines JSONB;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payout not found'; END IF;
  IF p_provider_reference IS NULL OR length(p_provider_reference) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'Provider payout reference is required';
  END IF;
  IF p_amount_minor <> v_payout.amount_minor OR upper(p_currency) <> v_payout.currency THEN
    RAISE EXCEPTION 'Provider payout amount or currency mismatch';
  END IF;
  IF v_payout.provider_reference IS NOT NULL AND v_payout.provider_reference <> p_provider_reference THEN
    RAISE EXCEPTION 'Provider payout reference mismatch';
  END IF;
  IF v_payout.state = 'succeeded' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'succeeded') THEN RAISE EXCEPTION 'Payout success transition is not allowed'; END IF;
  SELECT * INTO v_reservation FROM fund_reservations WHERE id = v_payout.reservation_id;
  v_pending_account := ensure_wallet_system_account(
    v_payout.organization_id,
    'WALLET.PENDING.' || upper(substr(md5(v_reservation.wallet_id::TEXT), 1, 24)),
    'Pending payout for wallet', 'liability', 'credit'
  );
  v_provider_account := ensure_wallet_system_account(
    v_payout.organization_id,
    'WALLET.CLEARING.' || upper(substr(md5(v_payout.provider_name), 1, 16)),
    'Payout provider clearing', 'asset', 'debit'
  );
  IF wallet_account_balance_minor(v_pending_account) < v_payout.amount_minor + v_payout.fee_amount_minor THEN
    RAISE EXCEPTION 'Pending payout liability is insufficient';
  END IF;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_pending_account, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_payout.amount_minor + v_payout.fee_amount_minor, 'memo', 'Settle pending payout'),
    jsonb_build_object('account_id', v_provider_account, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_payout.amount_minor + v_payout.fee_amount_minor, 'memo', 'Provider payout clearing')
  );
  v_journal_id := post_wallet_journal(
    v_payout.organization_id, 'payout.success', v_payout.id::TEXT, 'Successful wallet payout', v_lines
  );
  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  UPDATE payouts SET state = 'succeeded', provider_reference = p_provider_reference,
    success_journal_entry_id = v_journal_id, terminal_at = NOW(), updated_at = NOW()
  WHERE id = p_payout_id RETURNING * INTO v_payout;
  UPDATE withdrawal_requests SET status = 'SUCCESS', interswitch_ref = p_provider_reference, updated_at = NOW()
  WHERE id = v_payout.withdrawal_request_id;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION fail_wallet_payout(
  p_payout_id UUID, p_failure_code TEXT, p_failure_reason TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payout not found'; END IF;
  IF v_payout.state = 'failed' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'failed') THEN RAISE EXCEPTION 'Payout failure transition is not allowed'; END IF;
  PERFORM restore_wallet_reservation(v_payout.reservation_id, v_payout.actor_id, 'PAYOUT-FAIL-' || v_payout.id::TEXT);
  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  UPDATE payouts SET state = 'failed', failure_code = left(p_failure_code, 80),
    failure_reason = left(p_failure_reason, 500), terminal_at = NOW(), updated_at = NOW()
  WHERE id = p_payout_id RETURNING * INTO v_payout;
  UPDATE withdrawal_requests SET status = 'FAILED', failure_reason = left(p_failure_reason, 500), updated_at = NOW()
  WHERE id = v_payout.withdrawal_request_id;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION record_provider_event(
  p_organization_id UUID, p_payout_id UUID, p_provider_name TEXT, p_provider_environment TEXT,
  p_provider_event_id TEXT, p_event_type TEXT, p_raw_event_hash TEXT,
  p_normalized_payload JSONB, p_occurred_at TIMESTAMPTZ
) RETURNS provider_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_event provider_events;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_event FROM provider_events
  WHERE provider_name = p_provider_name AND provider_environment = p_provider_environment
    AND raw_event_hash = p_raw_event_hash;
  IF v_event.id IS NOT NULL THEN RETURN v_event; END IF;
  IF p_payout_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM payouts WHERE id = p_payout_id AND organization_id = p_organization_id
      AND provider_name = p_provider_name AND provider_environment = p_provider_environment
  ) THEN RAISE EXCEPTION 'Provider event payout ownership mismatch'; END IF;
  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  INSERT INTO provider_events(
    organization_id, payout_id, provider_name, provider_environment, provider_event_id,
    event_type, raw_event_hash, signature_verified, normalized_payload, occurred_at
  ) VALUES (
    p_organization_id, p_payout_id, p_provider_name, p_provider_environment, p_provider_event_id,
    p_event_type, p_raw_event_hash, TRUE, COALESCE(p_normalized_payload, '{}'::JSONB), p_occurred_at
  ) RETURNING * INTO v_event;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION finish_provider_event(
  p_event_id UUID, p_state TEXT, p_rejection_reason TEXT DEFAULT NULL
) RETURNS provider_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_event provider_events;
  v_previous_setting TEXT;
BEGIN
  IF p_state NOT IN ('processed', 'rejected') THEN RAISE EXCEPTION 'Provider event terminal state is invalid'; END IF;
  SELECT * INTO v_event FROM provider_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Provider event not found'; END IF;
  IF v_event.processing_state = p_state THEN RETURN v_event; END IF;
  IF v_event.processing_state <> 'received' THEN RAISE EXCEPTION 'Provider event is already terminal'; END IF;
  v_previous_setting := current_setting('microfams.payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  UPDATE provider_events SET processing_state = p_state,
    rejection_reason = CASE WHEN p_state = 'rejected' THEN left(p_rejection_reason, 500) END,
    processed_at = NOW()
  WHERE id = p_event_id RETURNING * INTO v_event;
  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_event;
END;
$$;

REVOKE ALL ON payouts, payout_attempts, provider_events, reconciliation_configurations,
  reconciliation_runs, reconciliation_items, reconciliation_exceptions FROM anon, authenticated;
ALTER TABLE payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE payout_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_configurations ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_exceptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_read ON payouts FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payout_attempts FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON provider_events FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON reconciliation_configurations FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON reconciliation_runs FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON reconciliation_items FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON reconciliation_exceptions FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON FUNCTION protect_payout_engine_records() FROM PUBLIC;
REVOKE ALL ON FUNCTION payout_transition_allowed(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_wallet_payout(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION mark_payout_submitted(UUID, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION succeed_wallet_payout(UUID, TEXT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fail_wallet_payout(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_provider_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION finish_provider_event(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_wallet_payout(UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION mark_payout_submitted(UUID, TEXT, TEXT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION succeed_wallet_payout(UUID, TEXT, BIGINT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION fail_wallet_payout(UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION record_provider_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION finish_provider_event(UUID, TEXT, TEXT) TO service_role;
