-- BS-09B: maker-checker recovery methods, approved offsets, write-offs, and late success.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS booking_recovery_offset_agreements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  maximum_amount_minor BIGINT NOT NULL CHECK (maximum_amount_minor > 0),
  effective_from TIMESTAMPTZ NOT NULL,
  effective_until TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'active', 'rejected', 'retired')),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 10 AND 500),
  evidence_reference TEXT NOT NULL
    CHECK (length(btrim(evidence_reference)) BETWEEN 4 AND 500),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  requested_by UUID NOT NULL REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  CHECK (effective_until > effective_from),
  CHECK (approved_by IS NULL OR approved_by <> requested_by)
);

CREATE TABLE IF NOT EXISTS booking_recovery_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  recovery_case_id UUID NOT NULL REFERENCES booking_recovery_cases(id),
  method TEXT NOT NULL CHECK (method IN (
    'supplier_repayment', 'provider_recovery', 'insurance',
    'future_settlement_offset', 'writeoff'
  )),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  offset_agreement_id UUID REFERENCES booking_recovery_offset_agreements(id),
  settlement_release_id UUID REFERENCES booking_settlement_releases(id),
  evidence_reference TEXT NOT NULL
    CHECK (length(btrim(evidence_reference)) BETWEEN 4 AND 500),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 10 AND 500),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'approved', 'rejected')),
  requested_by UUID NOT NULL REFERENCES users(id),
  decided_by UUID REFERENCES users(id),
  decided_at TIMESTAMPTZ,
  decision_reason TEXT,
  customer_journal_entry_id UUID REFERENCES journal_entries(id),
  provider_journal_entry_id UUID REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  CHECK (decided_by IS NULL OR decided_by <> requested_by),
  CHECK (
    (method = 'future_settlement_offset'
      AND offset_agreement_id IS NOT NULL AND settlement_release_id IS NOT NULL)
    OR
    (method <> 'future_settlement_offset'
      AND offset_agreement_id IS NULL AND settlement_release_id IS NULL)
  ),
  CHECK (
    (state = 'pending' AND decided_by IS NULL AND decided_at IS NULL)
    OR
    (state IN ('approved', 'rejected')
      AND decided_by IS NOT NULL AND decided_at IS NOT NULL
      AND decision_reason IS NOT NULL)
  )
);

DROP TRIGGER IF EXISTS booking_recovery_offset_agreements_engine_only
  ON booking_recovery_offset_agreements;
CREATE TRIGGER booking_recovery_offset_agreements_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_recovery_offset_agreements
  FOR EACH ROW EXECUTE FUNCTION booking_recovery_tables_engine_only();
DROP TRIGGER IF EXISTS booking_recovery_actions_engine_only ON booking_recovery_actions;
CREATE TRIGGER booking_recovery_actions_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_recovery_actions
  FOR EACH ROW EXECUTE FUNCTION booking_recovery_tables_engine_only();

CREATE OR REPLACE FUNCTION propose_booking_recovery_offset_agreement(
  p_organization_id UUID, p_provider_organization_id UUID, p_actor_id UUID,
  p_currency TEXT, p_maximum_amount_minor BIGINT,
  p_effective_from TIMESTAMPTZ, p_effective_until TIMESTAMPTZ,
  p_reason TEXT, p_evidence_reference TEXT, p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_old booking_recovery_offset_agreements;
  v_result booking_recovery_offset_agreements; v_hash TEXT; v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_provider_organization_id IS NULL
    OR p_organization_id = p_provider_organization_id OR p_actor_id IS NULL
    OR upper(COALESCE(p_currency, '')) !~ '^[A-Z]{3}$'
    OR COALESCE(p_maximum_amount_minor, 0) <= 0
    OR p_effective_from IS NULL OR p_effective_until <= p_effective_from
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(btrim(COALESCE(p_evidence_reference, ''))) NOT BETWEEN 4 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_AGREEMENT_INVALID'; END IF;
  IF NOT has_financial_permission(
    p_organization_id, p_actor_id, 'financial.reconciliation.manual'
  ) THEN RAISE EXCEPTION 'BOOKING_RECOVERY_NOT_AUTHORIZED'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organizations WHERE id = p_provider_organization_id
  ) THEN RAISE EXCEPTION 'BOOKING_RECOVERY_PROVIDER_NOT_FOUND'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id, p_provider_organization_id, p_actor_id,
    upper(p_currency), p_maximum_amount_minor, p_effective_from,
    p_effective_until, btrim(p_reason), btrim(p_evidence_reference)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_old FROM booking_recovery_offset_agreements
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_old.request_hash <> v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN to_jsonb(v_old);
  END IF;
  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  INSERT INTO booking_recovery_offset_agreements(
    organization_id, provider_organization_id, currency, maximum_amount_minor,
    effective_from, effective_until, reason, evidence_reference,
    idempotency_key, request_hash, requested_by
  ) VALUES (
    p_organization_id, p_provider_organization_id, upper(p_currency),
    p_maximum_amount_minor, p_effective_from, p_effective_until,
    btrim(p_reason), btrim(p_evidence_reference), p_idempotency_key,
    v_hash, p_actor_id
  ) RETURNING * INTO v_result;
  PERFORM set_config('microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE);
  RETURN to_jsonb(v_result);
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_recovery_offset_agreement(
  p_agreement_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_approve BOOLEAN, p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v booking_recovery_offset_agreements; v_target TEXT;
  v_previous TEXT;
BEGIN
  IF p_approve IS NULL OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_DECISION_INVALID'; END IF;
  IF NOT has_financial_permission(
    p_organization_id, p_actor_id, 'financial.reconciliation.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_RECOVERY_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v FROM booking_recovery_offset_agreements
  WHERE id = p_agreement_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_AGREEMENT_NOT_FOUND'; END IF;
  IF v.requested_by = p_actor_id THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_target := CASE WHEN p_approve THEN 'active' ELSE 'rejected' END;
  IF v.state <> 'pending' THEN
    IF v.state = v_target AND v.approved_by = p_actor_id THEN RETURN to_jsonb(v); END IF;
    RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_AGREEMENT_DECIDED';
  END IF;
  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  UPDATE booking_recovery_offset_agreements SET
    state = v_target, approved_by = p_actor_id, approved_at = NOW()
  WHERE id = v.id RETURNING * INTO v;
  PERFORM set_config('microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE);
  RETURN to_jsonb(v);
END;
$$;

CREATE OR REPLACE FUNCTION propose_booking_recovery_action(
  p_recovery_case_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_method TEXT, p_amount_minor BIGINT, p_offset_agreement_id UUID,
  p_settlement_release_id UUID, p_evidence_reference TEXT,
  p_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_case booking_recovery_cases; v_old booking_recovery_actions;
  v_action booking_recovery_actions; v_remaining BIGINT; v_hash TEXT; v_previous TEXT;
BEGIN
  IF p_method NOT IN (
      'supplier_repayment', 'provider_recovery', 'insurance',
      'future_settlement_offset', 'writeoff'
    ) OR COALESCE(p_amount_minor, 0) <= 0
    OR length(btrim(COALESCE(p_evidence_reference, ''))) NOT BETWEEN 4 AND 500
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR ((p_method = 'future_settlement_offset')
      <> (p_offset_agreement_id IS NOT NULL AND p_settlement_release_id IS NOT NULL))
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_ACTION_INVALID'; END IF;
  IF NOT has_financial_permission(
    p_organization_id, p_actor_id, 'financial.reconciliation.manual'
  ) THEN RAISE EXCEPTION 'BOOKING_RECOVERY_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_case FROM booking_recovery_cases
  WHERE id = p_recovery_case_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_RECOVERY_CASE_NOT_FOUND'; END IF;
  v_remaining := v_case.recoverable_amount_minor
    - v_case.recovered_amount_minor - v_case.loss_amount_minor
    - COALESCE((SELECT sum(amount_minor) FROM booking_recovery_actions
      WHERE recovery_case_id = v_case.id AND state = 'pending'), 0);
  IF p_amount_minor > v_remaining THEN RAISE EXCEPTION 'BOOKING_RECOVERY_AMOUNT_EXCEEDS_REMAINING'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_recovery_case_id, p_organization_id, p_actor_id, p_method,
    p_amount_minor, p_offset_agreement_id, p_settlement_release_id,
    btrim(p_evidence_reference), btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_old FROM booking_recovery_actions
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_old.request_hash <> v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN to_jsonb(v_old);
  END IF;
  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  INSERT INTO booking_recovery_actions(
    organization_id, recovery_case_id, method, amount_minor, currency,
    offset_agreement_id, settlement_release_id, evidence_reference,
    reason, idempotency_key, request_hash, requested_by
  ) VALUES (
    p_organization_id, v_case.id, p_method, p_amount_minor, v_case.currency,
    p_offset_agreement_id, p_settlement_release_id, btrim(p_evidence_reference),
    btrim(p_reason), p_idempotency_key, v_hash, p_actor_id
  ) RETURNING * INTO v_action;
  PERFORM set_config('microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE);
  RETURN to_jsonb(v_action);
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_recovery_action(
  p_action_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_approve BOOLEAN, p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_action booking_recovery_actions; v_case booking_recovery_cases;
  v_agreement booking_recovery_offset_agreements;
  v_release booking_settlement_releases; v_remaining BIGINT;
  v_customer_debit UUID; v_customer_credit UUID;
  v_provider_debit UUID; v_provider_credit UUID;
  v_customer_journal UUID; v_provider_journal UUID;
  v_previous TEXT; v_target TEXT;
BEGIN
  IF p_approve IS NULL OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_DECISION_INVALID'; END IF;
  IF NOT has_financial_permission(
    p_organization_id, p_actor_id, 'financial.reconciliation.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_RECOVERY_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_action FROM booking_recovery_actions
  WHERE id = p_action_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_RECOVERY_ACTION_NOT_FOUND'; END IF;
  IF v_action.requested_by = p_actor_id THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_target := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  IF v_action.state <> 'pending' THEN
    IF v_action.state = v_target AND v_action.decided_by = p_actor_id
    THEN RETURN to_jsonb(v_action); END IF;
    RAISE EXCEPTION 'BOOKING_RECOVERY_ACTION_DECIDED';
  END IF;
  SELECT * INTO v_case FROM booking_recovery_cases
  WHERE id = v_action.recovery_case_id FOR UPDATE;
  v_remaining := v_case.recoverable_amount_minor
    - v_case.recovered_amount_minor - v_case.loss_amount_minor;
  IF v_action.amount_minor > v_remaining
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_AMOUNT_EXCEEDS_REMAINING'; END IF;
  IF p_approve THEN
    IF v_action.method = 'future_settlement_offset' THEN
      SELECT * INTO v_agreement FROM booking_recovery_offset_agreements
      WHERE id = v_action.offset_agreement_id
        AND organization_id = v_case.organization_id
        AND provider_organization_id = v_case.provider_organization_id
        AND currency = v_case.currency AND state = 'active'
        AND NOW() BETWEEN effective_from AND effective_until
      FOR UPDATE;
      IF NOT FOUND
        OR v_action.amount_minor + COALESCE((
          SELECT sum(amount_minor) FROM booking_recovery_actions
          WHERE offset_agreement_id = v_agreement.id
            AND state = 'approved' AND id <> v_action.id
        ), 0) > v_agreement.maximum_amount_minor
      THEN RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_AGREEMENT_INVALID'; END IF;
      SELECT * INTO v_release FROM booking_settlement_releases
      WHERE id = v_action.settlement_release_id
        AND organization_id = v_case.organization_id
        AND provider_organization_id = v_case.provider_organization_id
        AND currency = v_case.currency
      FOR UPDATE;
      IF NOT FOUND
        OR v_action.amount_minor + COALESCE((
          SELECT sum(amount_minor) FROM booking_recovery_actions
          WHERE settlement_release_id = v_release.id
            AND state = 'approved' AND id <> v_action.id
        ), 0) > v_release.supplier_amount_minor
        OR EXISTS (
          SELECT 1 FROM payouts WHERE booking_settlement_release_id = v_release.id
            AND state NOT IN ('failed', 'cancelled')
        )
      THEN RAISE EXCEPTION 'BOOKING_RECOVERY_OFFSET_RELEASE_INVALID'; END IF;
      v_customer_debit := ensure_booking_settlement_account(
        v_case.organization_id, v_case.provider_organization_id, p_actor_id,
        'interorganization_settlement_due_to', v_case.currency
      );
      v_provider_credit := ensure_booking_settlement_account(
        v_case.provider_organization_id, v_case.organization_id, p_actor_id,
        'interorganization_settlement_due_from', v_case.currency
      );
    ELSE
      v_customer_debit := ensure_booking_settlement_account(
        v_case.organization_id, NULL, p_actor_id,
        CASE WHEN v_action.method = 'writeoff'
          THEN 'dispute_chargeback_loss'
          ELSE 'booking_payout_provider_clearing' END, v_case.currency
      );
      v_provider_credit := ensure_booking_settlement_account(
        v_case.provider_organization_id, v_case.organization_id, p_actor_id,
        CASE WHEN v_action.method = 'writeoff'
          THEN 'supplier_booking_service_revenue'
          ELSE 'supplier_external_bank_asset' END, v_case.currency
      );
    END IF;
    v_customer_credit := ensure_booking_settlement_account(
      v_case.organization_id, v_case.provider_organization_id, p_actor_id,
      'dispute_recovery_receivable', v_case.currency
    );
    v_provider_debit := ensure_booking_settlement_account(
      v_case.provider_organization_id, v_case.organization_id, p_actor_id,
      'booking_recovery_payable', v_case.currency
    );
    v_customer_journal := post_booking_settlement_journal(
      v_case.organization_id, p_actor_id, v_case.currency,
      'booking.recovery.' || v_action.method, v_action.id::TEXT,
      'booking.recovery.customer:' || v_action.id::TEXT, v_case.correlation_id,
      'Apply approved booking recovery action',
      jsonb_build_array(
        jsonb_build_object('account_id', v_customer_debit, 'line_number', 1,
          'side', 'debit', 'amount_minor', v_action.amount_minor),
        jsonb_build_object('account_id', v_customer_credit, 'line_number', 2,
          'side', 'credit', 'amount_minor', v_action.amount_minor)
      )
    );
    v_provider_journal := post_booking_settlement_journal(
      v_case.provider_organization_id, p_actor_id, v_case.currency,
      'booking.recovery.' || v_action.method, v_action.id::TEXT,
      'booking.recovery.provider:' || v_action.id::TEXT, v_case.correlation_id,
      'Apply approved provider recovery obligation',
      jsonb_build_array(
        jsonb_build_object('account_id', v_provider_debit, 'line_number', 1,
          'side', 'debit', 'amount_minor', v_action.amount_minor),
        jsonb_build_object('account_id', v_provider_credit, 'line_number', 2,
          'side', 'credit', 'amount_minor', v_action.amount_minor)
      )
    );
  END IF;
  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  UPDATE booking_recovery_actions SET state = v_target, decided_by = p_actor_id,
    decided_at = NOW(), decision_reason = btrim(p_reason),
    customer_journal_entry_id = v_customer_journal,
    provider_journal_entry_id = v_provider_journal
  WHERE id = v_action.id RETURNING * INTO v_action;
  IF p_approve THEN
    UPDATE booking_recovery_cases SET
      recovered_amount_minor = recovered_amount_minor
        + CASE WHEN v_action.method = 'writeoff' THEN 0 ELSE v_action.amount_minor END,
      loss_amount_minor = loss_amount_minor
        + CASE WHEN v_action.method = 'writeoff' THEN v_action.amount_minor ELSE 0 END,
      state = CASE
        WHEN recovered_amount_minor + loss_amount_minor + v_action.amount_minor
          = recoverable_amount_minor
        THEN CASE WHEN v_action.method = 'writeoff' THEN 'written_off' ELSE 'recovered' END
        ELSE 'partially_recovered' END,
      updated_at = NOW()
    WHERE id = v_case.id;
  END IF;
  PERFORM set_config('microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE);
  RETURN to_jsonb(v_action);
END;
$$;

CREATE OR REPLACE FUNCTION record_booking_late_payout_success(
  p_payout_id UUID, p_organization_id UUID, p_provider_reference TEXT,
  p_amount_minor BIGINT, p_currency TEXT, p_beneficiary_fingerprint TEXT,
  p_provider_name TEXT, p_provider_environment TEXT, p_evidence_snapshot JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_payout payouts; v_existing booking_late_payout_success_exceptions;
  v_result booking_late_payout_success_exceptions; v_previous TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts
  WHERE id = p_payout_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'booking_settlement'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND'; END IF;
  IF v_payout.state NOT IN ('failed', 'cancelled')
  THEN RAISE EXCEPTION 'BOOKING_LATE_PAYOUT_SUCCESS_NOT_APPLICABLE'; END IF;
  IF p_provider_reference IS NULL OR p_amount_minor <> v_payout.amount_minor
    OR upper(p_currency) <> v_payout.currency
    OR p_beneficiary_fingerprint <> v_payout.beneficiary_fingerprint
    OR p_provider_name <> v_payout.provider_name
    OR p_provider_environment <> v_payout.provider_environment
    OR jsonb_typeof(p_evidence_snapshot) <> 'object'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH'; END IF;
  SELECT * INTO v_existing FROM booking_late_payout_success_exceptions
  WHERE payout_id = p_payout_id AND provider_reference = p_provider_reference;
  IF FOUND THEN RETURN to_jsonb(v_existing); END IF;
  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  INSERT INTO booking_late_payout_success_exceptions(
    organization_id, payout_id, provider_reference, amount_minor, currency,
    beneficiary_fingerprint, evidence_snapshot
  ) VALUES (
    p_organization_id, p_payout_id, p_provider_reference, p_amount_minor,
    upper(p_currency), p_beneficiary_fingerprint, p_evidence_snapshot
      || jsonb_build_object('recorded_without_repaying', TRUE)
  ) RETURNING * INTO v_result;
  PERFORM set_config('microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE);
  RETURN to_jsonb(v_result);
END;
$$;

ALTER TABLE booking_recovery_offset_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_recovery_actions ENABLE ROW LEVEL SECURITY;
CREATE POLICY booking_recovery_offset_tenant_read ON booking_recovery_offset_agreements
  FOR SELECT USING (
    has_active_organization_membership(organization_id)
    OR has_active_organization_membership(provider_organization_id)
  );
CREATE POLICY booking_recovery_action_tenant_read ON booking_recovery_actions
  FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON booking_recovery_offset_agreements, booking_recovery_actions
  FROM anon, authenticated;
GRANT SELECT ON booking_recovery_offset_agreements, booking_recovery_actions
  TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_recovery_offset_agreements,
  booking_recovery_actions FROM service_role;
REVOKE ALL ON FUNCTION propose_booking_recovery_offset_agreement(
  UUID, UUID, UUID, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_booking_recovery_offset_agreement(
  UUID, UUID, UUID, BOOLEAN, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION propose_booking_recovery_action(
  UUID, UUID, UUID, TEXT, BIGINT, UUID, UUID, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_booking_recovery_action(
  UUID, UUID, UUID, BOOLEAN, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_booking_late_payout_success(
  UUID, UUID, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION propose_booking_recovery_offset_agreement(
  UUID, UUID, UUID, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_recovery_offset_agreement(
  UUID, UUID, UUID, BOOLEAN, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION propose_booking_recovery_action(
  UUID, UUID, UUID, TEXT, BIGINT, UUID, UUID, TEXT, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_recovery_action(
  UUID, UUID, UUID, BOOLEAN, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION record_booking_late_payout_success(
  UUID, UUID, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB
) TO service_role;
