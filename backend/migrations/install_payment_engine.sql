-- Atomic inbound-payment acquisition and confirmation commands.

CREATE OR REPLACE FUNCTION create_payment_intent(
  p_organization_id UUID, p_source_type TEXT, p_source_id UUID, p_payer_id UUID,
  p_internal_reference TEXT, p_idempotency_key TEXT, p_provider_name TEXT,
  p_provider_environment TEXT, p_currency TEXT, p_amount_minor BIGINT,
  p_correlation_id UUID, p_actor_id UUID
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_existing payments; v_result payments; v_hash TEXT; v_previous TEXT;
BEGIN
  IF p_source_type NOT IN ('booking', 'marketplace_order', 'wallet', 'group_membership', 'contribution')
    OR p_source_id IS NULL THEN RAISE EXCEPTION 'Payment source is invalid'; END IF;
  IF p_amount_minor <= 0 OR upper(p_currency) <> 'NGN' THEN RAISE EXCEPTION 'Payment money is invalid'; END IF;
  IF p_provider_environment NOT IN ('deterministic', 'sandbox', 'live') THEN RAISE EXCEPTION 'Provider environment is invalid'; END IF;
  IF p_internal_reference IS NULL OR length(p_internal_reference) NOT BETWEEN 8 AND 160
    OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160
    THEN RAISE EXCEPTION 'Payment references are invalid'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_organization_id, p_source_type, p_source_id,
    p_payer_id, p_internal_reference, p_provider_name, p_provider_environment, upper(p_currency),
    p_amount_minor, p_correlation_id, p_actor_id), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM payments
    WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key FOR UPDATE;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'Payment replay changed the original request'; END IF;
    RETURN v_existing;
  END IF;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payments(organization_id, source_type, source_id, payer_id, internal_reference,
    idempotency_key, request_hash, provider_name, provider_environment, currency, amount_minor,
    correlation_id, actor_id)
  VALUES (p_organization_id, p_source_type, p_source_id, p_payer_id, p_internal_reference,
    p_idempotency_key, v_hash, p_provider_name, p_provider_environment, upper(p_currency),
    p_amount_minor, p_correlation_id, p_actor_id)
  RETURNING * INTO v_result;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION mark_payment_initialized(
  p_payment_id UUID, p_request_hash TEXT, p_provider_reference TEXT, p_state TEXT,
  p_action_expires_at TIMESTAMPTZ DEFAULT NULL
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_attempt INTEGER; v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF NOT payment_transition_allowed(v_payment.state, p_state)
    OR p_state NOT IN ('requires_action', 'processing') THEN RAISE EXCEPTION 'Payment initialization transition is not allowed'; END IF;
  IF v_payment.provider_reference IS NOT NULL AND p_provider_reference IS NOT NULL
    AND v_payment.provider_reference <> p_provider_reference THEN RAISE EXCEPTION 'Payment provider reference mismatch'; END IF;
  IF v_payment.state = p_state AND v_payment.provider_reference IS NOT DISTINCT FROM p_provider_reference THEN RETURN v_payment; END IF;
  SELECT COALESCE(max(attempt_number), 0) + 1 INTO v_attempt FROM payment_attempts WHERE payment_id = p_payment_id;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payment_attempts(organization_id, payment_id, attempt_number, request_hash, state,
    provider_reference, completed_at)
  VALUES (v_payment.organization_id, v_payment.id, v_attempt, p_request_hash, p_state,
    p_provider_reference, NOW());
  UPDATE payments SET state = p_state, provider_reference = COALESCE(p_provider_reference, provider_reference),
    action_expires_at = p_action_expires_at, initialized_at = COALESCE(initialized_at, NOW()), updated_at = NOW()
    WHERE id = p_payment_id RETURNING * INTO v_payment;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_payment;
END;
$$;

CREATE OR REPLACE FUNCTION succeed_inbound_payment(
  p_payment_id UUID, p_provider_reference TEXT, p_amount_minor BIGINT, p_currency TEXT
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_clearing UUID; v_funds UUID; v_journal UUID; v_lines JSONB; v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF p_amount_minor <> v_payment.amount_minor OR upper(p_currency) <> v_payment.currency THEN
    RAISE EXCEPTION 'Provider payment amount or currency mismatch'; END IF;
  IF v_payment.provider_reference IS NOT NULL AND p_provider_reference IS NOT NULL
    AND v_payment.provider_reference <> p_provider_reference THEN RAISE EXCEPTION 'Payment provider reference mismatch'; END IF;
  IF v_payment.state IN ('succeeded', 'partially_refunded', 'refunded') THEN RETURN v_payment; END IF;
  IF NOT payment_transition_allowed(v_payment.state, 'succeeded') THEN RAISE EXCEPTION 'Payment success transition is not allowed'; END IF;
  v_clearing := ensure_wallet_system_account(v_payment.organization_id,
    'PAYMENT.CLEARING.' || upper(substr(md5(v_payment.provider_name), 1, 16)),
    'Inbound payment provider clearing', 'asset', 'debit');
  v_funds := ensure_wallet_system_account(v_payment.organization_id,
    'PAYMENT.CUSTOMER_FUNDS', 'Inbound customer funds pending allocation', 'liability', 'credit');
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_clearing, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_payment.amount_minor, 'memo', 'Provider clearing receivable'),
    jsonb_build_object('account_id', v_funds, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_payment.amount_minor, 'memo', 'Customer funds pending allocation')
  );
  v_journal := post_wallet_journal(v_payment.organization_id, 'payment.success', v_payment.id::TEXT,
    'Confirmed inbound payment', v_lines);
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  UPDATE payments SET state = 'succeeded', provider_reference = COALESCE(p_provider_reference, provider_reference),
    success_journal_entry_id = v_journal, terminal_at = NOW(), updated_at = NOW()
    WHERE id = p_payment_id RETURNING * INTO v_payment;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_payment;
END;
$$;

CREATE OR REPLACE FUNCTION fail_inbound_payment(
  p_payment_id UUID, p_state TEXT, p_failure_code TEXT, p_failure_reason TEXT
) RETURNS payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_previous TEXT;
BEGIN
  IF p_state NOT IN ('failed', 'cancelled', 'expired') THEN RAISE EXCEPTION 'Payment terminal state is invalid'; END IF;
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF v_payment.state = p_state THEN RETURN v_payment; END IF;
  IF NOT payment_transition_allowed(v_payment.state, p_state) THEN RAISE EXCEPTION 'Payment failure transition is not allowed'; END IF;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  UPDATE payments SET state = p_state, failure_code = left(p_failure_code, 80),
    failure_reason = left(p_failure_reason, 500), terminal_at = NOW(), updated_at = NOW()
    WHERE id = p_payment_id RETURNING * INTO v_payment;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION create_payment_intent(UUID, TEXT, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION mark_payment_initialized(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION succeed_inbound_payment(UUID, TEXT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fail_inbound_payment(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_payment_intent(UUID, TEXT, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION mark_payment_initialized(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION succeed_inbound_payment(UUID, TEXT, BIGINT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION fail_inbound_payment(UUID, TEXT, TEXT, TEXT) TO service_role;
REVOKE ALL ON FUNCTION protect_payment_engine_records() FROM PUBLIC;
REVOKE ALL ON FUNCTION payment_transition_allowed(TEXT, TEXT) FROM PUBLIC;
