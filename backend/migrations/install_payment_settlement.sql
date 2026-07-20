-- Provider settlement, durable webhook receipts and tenant read isolation.

CREATE OR REPLACE FUNCTION post_provider_settlement(
  p_organization_id UUID, p_provider_name TEXT, p_provider_environment TEXT,
  p_provider_reference TEXT, p_currency TEXT, p_gross_amount_minor BIGINT,
  p_fee_amount_minor BIGINT, p_source_hash TEXT, p_settled_at TIMESTAMPTZ
) RETURNS settlements
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_existing settlements; v_result settlements; v_bank UUID; v_clearing UUID; v_fee UUID;
  v_journal UUID; v_lines JSONB; v_previous TEXT;
BEGIN
  SELECT * INTO v_existing FROM settlements WHERE provider_name = p_provider_name
    AND provider_environment = p_provider_environment AND source_hash = p_source_hash;
  IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
  IF p_gross_amount_minor <= 0 OR p_fee_amount_minor < 0 OR p_fee_amount_minor >= p_gross_amount_minor
    OR upper(p_currency) <> 'NGN' THEN RAISE EXCEPTION 'Settlement money is invalid'; END IF;
  v_bank := ensure_wallet_system_account(p_organization_id, 'PAYMENT.BANK_CASH',
    'Operating bank cash', 'asset', 'debit');
  v_clearing := ensure_wallet_system_account(p_organization_id,
    'PAYMENT.CLEARING.' || upper(substr(md5(p_provider_name), 1, 16)),
    'Inbound payment provider clearing', 'asset', 'debit');
  v_fee := ensure_wallet_system_account(p_organization_id, 'PAYMENT.PROVIDER_FEES',
    'Provider processing fees', 'expense', 'debit');
  v_lines := CASE WHEN p_fee_amount_minor = 0 THEN jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'line_number', 1, 'side', 'debit',
        'amount_minor', p_gross_amount_minor, 'memo', 'Net bank settlement'),
      jsonb_build_object('account_id', v_clearing, 'line_number', 2, 'side', 'credit',
        'amount_minor', p_gross_amount_minor, 'memo', 'Clear settled provider receivable')
    ) ELSE jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'line_number', 1, 'side', 'debit',
        'amount_minor', p_gross_amount_minor - p_fee_amount_minor, 'memo', 'Net bank settlement'),
      jsonb_build_object('account_id', v_fee, 'line_number', 2, 'side', 'debit',
        'amount_minor', p_fee_amount_minor, 'memo', 'Provider processing fee'),
      jsonb_build_object('account_id', v_clearing, 'line_number', 3, 'side', 'credit',
        'amount_minor', p_gross_amount_minor, 'memo', 'Clear settled provider receivable')
    ) END;
  v_journal := post_wallet_journal(p_organization_id, 'payment.settlement', p_provider_reference,
    'Provider settlement and processing fee', v_lines);
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO settlements(organization_id, provider_name, provider_environment, provider_reference,
    currency, gross_amount_minor, fee_amount_minor, net_amount_minor, source_hash, state,
    settled_at, journal_entry_id)
  VALUES (p_organization_id, p_provider_name, p_provider_environment, p_provider_reference,
    upper(p_currency), p_gross_amount_minor, p_fee_amount_minor,
    p_gross_amount_minor - p_fee_amount_minor, p_source_hash, 'posted', p_settled_at, v_journal)
  RETURNING * INTO v_result;
  IF p_fee_amount_minor > 0 THEN
    INSERT INTO payment_fees(organization_id, settlement_id, fee_type, payer_type, beneficiary_type,
      rule_version, amount_minor, currency, journal_entry_id)
    VALUES (p_organization_id, v_result.id, 'provider_processing', 'organization', 'provider',
      'provider-statement-v1', p_fee_amount_minor, upper(p_currency), v_journal);
  END IF;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION record_payment_provider_event(
  p_organization_id UUID, p_payment_id UUID, p_provider_name TEXT, p_provider_environment TEXT,
  p_provider_event_id TEXT, p_event_type TEXT, p_raw_event_hash TEXT,
  p_normalized_payload JSONB, p_occurred_at TIMESTAMPTZ
) RETURNS payment_provider_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_event payment_provider_events; v_previous TEXT;
BEGIN
  SELECT * INTO v_event FROM payment_provider_events WHERE provider_name = p_provider_name
    AND provider_environment = p_provider_environment AND raw_event_hash = p_raw_event_hash;
  IF v_event.id IS NOT NULL THEN RETURN v_event; END IF;
  IF NOT EXISTS (SELECT 1 FROM payments WHERE id = p_payment_id AND organization_id = p_organization_id
    AND provider_name = p_provider_name AND provider_environment = p_provider_environment)
    THEN RAISE EXCEPTION 'Provider event payment ownership mismatch'; END IF;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  INSERT INTO payment_provider_events(organization_id, payment_id, provider_name, provider_environment,
    provider_event_id, event_type, raw_event_hash, signature_verified, normalized_payload, occurred_at)
  VALUES (p_organization_id, p_payment_id, p_provider_name, p_provider_environment, p_provider_event_id,
    p_event_type, p_raw_event_hash, TRUE, COALESCE(p_normalized_payload, '{}'::JSONB), p_occurred_at)
  RETURNING * INTO v_event;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION finish_payment_provider_event(
  p_event_id UUID, p_state TEXT, p_rejection_reason TEXT DEFAULT NULL
) RETURNS payment_provider_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_event payment_provider_events; v_previous TEXT;
BEGIN
  IF p_state NOT IN ('processed', 'rejected') THEN RAISE EXCEPTION 'Provider event terminal state is invalid'; END IF;
  SELECT * INTO v_event FROM payment_provider_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Provider event not found'; END IF;
  IF v_event.processing_state = p_state THEN RETURN v_event; END IF;
  IF v_event.processing_state <> 'received' THEN RAISE EXCEPTION 'Provider event is already terminal'; END IF;
  v_previous := current_setting('microfams.payment_engine', TRUE);
  PERFORM set_config('microfams.payment_engine', 'on', TRUE);
  UPDATE payment_provider_events SET processing_state = p_state,
    rejection_reason = CASE WHEN p_state = 'rejected' THEN left(p_rejection_reason, 500) END,
    processed_at = NOW() WHERE id = p_event_id RETURNING * INTO v_event;
  PERFORM set_config('microfams.payment_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_event;
END;
$$;

REVOKE ALL ON payments, payment_attempts, payment_refunds, payment_reversals, payment_fees,
  settlements, settlement_items, payment_provider_events FROM anon, authenticated;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_reversals ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_fees ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_provider_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON payments FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payment_attempts FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payment_refunds FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payment_reversals FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payment_fees FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON settlements FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON settlement_items FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON payment_provider_events FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON FUNCTION post_provider_settlement(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BIGINT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_payment_provider_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION finish_payment_provider_event(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION post_provider_settlement(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BIGINT, TEXT, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION record_payment_provider_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION finish_payment_provider_event(UUID, TEXT, TEXT) TO service_role;
