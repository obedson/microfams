-- Refund and provider-reversal commands remain available when acquisition is disabled.

CREATE OR REPLACE FUNCTION create_payment_refund(
  p_payment_id UUID, p_internal_reference TEXT, p_idempotency_key TEXT, p_amount_minor BIGINT,
  p_reason_code TEXT, p_reason TEXT, p_actor_id UUID, p_approval_reference TEXT DEFAULT NULL
) RETURNS payment_refunds
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_existing payment_refunds; v_result payment_refunds;
  v_refunded BIGINT; v_hash TEXT; v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND OR v_payment.state NOT IN ('succeeded', 'partially_refunded') THEN RAISE EXCEPTION 'Payment is not refundable'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_payment_id, p_internal_reference, p_amount_minor,
    p_reason_code, p_reason, p_actor_id, p_approval_reference), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM payment_refunds
    WHERE organization_id = v_payment.organization_id AND idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'Refund replay changed the original request'; END IF;
    RETURN v_existing;
  END IF;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded FROM payment_refunds
    WHERE payment_id = p_payment_id AND state IN ('created', 'submitted', 'processing', 'succeeded');
  IF p_amount_minor <= 0 OR v_refunded + p_amount_minor > v_payment.amount_minor THEN
    RAISE EXCEPTION 'Refund exceeds remaining refundable amount'; END IF;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payment_refunds(organization_id, payment_id, internal_reference, idempotency_key,
    request_hash, amount_minor, currency, reason_code, reason, actor_id, approval_reference)
  VALUES (v_payment.organization_id, v_payment.id, p_internal_reference, p_idempotency_key, v_hash,
    p_amount_minor, v_payment.currency, p_reason_code, p_reason, p_actor_id, p_approval_reference)
  RETURNING * INTO v_result;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION apply_payment_refund_result(
  p_refund_id UUID, p_provider_reference TEXT, p_state TEXT, p_failure_code TEXT DEFAULT NULL,
  p_failure_reason TEXT DEFAULT NULL
) RETURNS payment_refunds
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_refund payment_refunds; v_payment payments; v_refunded BIGINT;
  v_clearing UUID; v_funds UUID; v_journal UUID; v_lines JSONB; v_previous TEXT;
BEGIN
  SELECT * INTO v_refund FROM payment_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found'; END IF;
  IF p_state NOT IN ('submitted', 'processing', 'succeeded', 'failed', 'cancelled') THEN RAISE EXCEPTION 'Refund state is invalid'; END IF;
  IF v_refund.state = p_state THEN RETURN v_refund; END IF;
  IF v_refund.state = 'created' AND p_state NOT IN ('submitted', 'processing', 'succeeded', 'failed', 'cancelled')
    OR v_refund.state = 'submitted' AND p_state NOT IN ('processing', 'succeeded', 'failed')
    OR v_refund.state = 'processing' AND p_state NOT IN ('succeeded', 'failed')
    OR v_refund.state IN ('succeeded', 'failed', 'cancelled') THEN RAISE EXCEPTION 'Refund transition is not allowed'; END IF;
  SELECT * INTO v_payment FROM payments WHERE id = v_refund.payment_id FOR UPDATE;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  IF p_state = 'succeeded' THEN
    v_clearing := ensure_wallet_system_account(v_payment.organization_id,
      'PAYMENT.CLEARING.' || upper(substr(md5(v_payment.provider_name), 1, 16)),
      'Inbound payment provider clearing', 'asset', 'debit');
    v_funds := ensure_wallet_system_account(v_payment.organization_id,
      'PAYMENT.CUSTOMER_FUNDS', 'Inbound customer funds pending allocation', 'liability', 'credit');
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_funds, 'line_number', 1, 'side', 'debit',
        'amount_minor', v_refund.amount_minor, 'memo', 'Refund customer funds'),
      jsonb_build_object('account_id', v_clearing, 'line_number', 2, 'side', 'credit',
        'amount_minor', v_refund.amount_minor, 'memo', 'Provider refund clearing')
    );
    v_journal := post_wallet_journal(v_payment.organization_id, 'payment.refund', v_refund.id::TEXT,
      'Successful payment refund', v_lines);
  END IF;
  UPDATE payment_refunds SET state = p_state, provider_reference = COALESCE(p_provider_reference, provider_reference),
    journal_entry_id = COALESCE(v_journal, journal_entry_id), failure_code = left(p_failure_code, 80),
    failure_reason = left(p_failure_reason, 500),
    terminal_at = CASE WHEN p_state IN ('succeeded', 'failed', 'cancelled') THEN NOW() ELSE NULL END,
    updated_at = NOW() WHERE id = p_refund_id RETURNING * INTO v_refund;
  IF p_state = 'succeeded' THEN
    SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded FROM payment_refunds
      WHERE payment_id = v_payment.id AND state = 'succeeded';
    UPDATE payments SET state = CASE WHEN v_refunded = amount_minor THEN 'refunded' ELSE 'partially_refunded' END,
      updated_at = NOW() WHERE id = v_payment.id;
  END IF;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_refund;
END;
$$;

CREATE OR REPLACE FUNCTION reverse_inbound_payment(
  p_payment_id UUID, p_provider_event_id TEXT, p_internal_reference TEXT,
  p_amount_minor BIGINT, p_reason TEXT, p_occurred_at TIMESTAMPTZ
) RETURNS payment_reversals
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_payment payments; v_existing payment_reversals; v_clearing UUID; v_funds UUID;
  v_journal UUID; v_lines JSONB; v_result payment_reversals; v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND OR v_payment.state NOT IN ('succeeded', 'partially_refunded') THEN RAISE EXCEPTION 'Payment is not reversible'; END IF;
  SELECT * INTO v_existing FROM payment_reversals WHERE payment_id = p_payment_id AND provider_event_id = p_provider_event_id;
  IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
  IF p_amount_minor <> v_payment.amount_minor THEN RAISE EXCEPTION 'Partial provider reversals require a dispute workflow'; END IF;
  v_clearing := ensure_wallet_system_account(v_payment.organization_id,
    'PAYMENT.CLEARING.' || upper(substr(md5(v_payment.provider_name), 1, 16)),
    'Inbound payment provider clearing', 'asset', 'debit');
  v_funds := ensure_wallet_system_account(v_payment.organization_id,
    'PAYMENT.CUSTOMER_FUNDS', 'Inbound customer funds pending allocation', 'liability', 'credit');
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_funds, 'line_number', 1, 'side', 'debit',
      'amount_minor', p_amount_minor, 'memo', 'Reverse customer funds'),
    jsonb_build_object('account_id', v_clearing, 'line_number', 2, 'side', 'credit',
      'amount_minor', p_amount_minor, 'memo', 'Provider reversal clearing')
  );
  v_journal := post_wallet_journal(v_payment.organization_id, 'payment.reversal', p_internal_reference,
    'Provider payment reversal', v_lines);
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payment_reversals(organization_id, payment_id, provider_event_id, internal_reference,
    amount_minor, currency, reason, journal_entry_id, occurred_at)
  VALUES (v_payment.organization_id, v_payment.id, p_provider_event_id, p_internal_reference,
    p_amount_minor, v_payment.currency, p_reason, v_journal, p_occurred_at)
  RETURNING * INTO v_result;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION create_payment_refund(UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION apply_payment_refund_result(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION reverse_inbound_payment(UUID, TEXT, TEXT, BIGINT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_payment_refund(UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION apply_payment_refund_result(UUID, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION reverse_inbound_payment(UUID, TEXT, TEXT, BIGINT, TEXT, TIMESTAMPTZ) TO service_role;
