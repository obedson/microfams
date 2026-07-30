-- BS-09A: classify provider reversals without mutating original payment or payout evidence.

SET search_path = public, extensions;

INSERT INTO financial_account_purpose_rules(
  purpose, account_class, normal_side, allowed_owner_types, is_control
) VALUES
  ('booking_recovery_payable', 'liability', 'credit', ARRAY['system'], TRUE)
ON CONFLICT (purpose) DO NOTHING;

CREATE TABLE IF NOT EXISTS booking_recovery_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  payment_reversal_id UUID NOT NULL UNIQUE REFERENCES payment_reversals(id),
  payout_id UUID REFERENCES payouts(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  reversed_amount_minor BIGINT NOT NULL CHECK (reversed_amount_minor > 0),
  escrow_recovered_minor BIGINT NOT NULL DEFAULT 0 CHECK (escrow_recovered_minor >= 0),
  unpaid_compensated_minor BIGINT NOT NULL DEFAULT 0 CHECK (unpaid_compensated_minor >= 0),
  recoverable_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (recoverable_amount_minor >= 0),
  recovered_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (recovered_amount_minor >= 0),
  loss_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (loss_amount_minor >= 0),
  state TEXT NOT NULL CHECK (state IN (
    'open', 'partially_recovered', 'recovered', 'written_off', 'closed'
  )),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  correlation_id UUID NOT NULL,
  customer_journal_entry_id UUID REFERENCES journal_entries(id),
  provider_journal_entry_id UUID REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    escrow_recovered_minor + unpaid_compensated_minor + recoverable_amount_minor
      = reversed_amount_minor
  ),
  CHECK (recovered_amount_minor + loss_amount_minor <= recoverable_amount_minor),
  CHECK (organization_id <> provider_organization_id)
);

CREATE TABLE IF NOT EXISTS booking_recovery_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  recovery_case_id UUID NOT NULL REFERENCES booking_recovery_cases(id),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'reversal_classified', 'recovery_required', 'reconciliation_exception'
  )),
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  evidence_snapshot JSONB NOT NULL CHECK (jsonb_typeof(evidence_snapshot) = 'object'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (recovery_case_id, event_type)
);

CREATE TABLE IF NOT EXISTS booking_late_payout_success_exceptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payout_id UUID NOT NULL REFERENCES payouts(id),
  provider_event_id UUID REFERENCES provider_events(id),
  provider_reference TEXT NOT NULL CHECK (length(provider_reference) BETWEEN 1 AND 160),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  beneficiary_fingerprint VARCHAR(64) NOT NULL
    CHECK (beneficiary_fingerprint ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'investigating', 'resolved')),
  evidence_snapshot JSONB NOT NULL CHECK (jsonb_typeof(evidence_snapshot) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (payout_id, provider_reference)
);

CREATE OR REPLACE FUNCTION booking_recovery_tables_engine_only() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('microfams.booking_recovery_engine', TRUE) IS DISTINCT FROM 'on'
  THEN RAISE EXCEPTION 'BOOKING_RECOVERY_ENGINE_REQUIRED'; END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'BOOKING_RECOVERY_EVIDENCE_IMMUTABLE';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS booking_recovery_cases_engine_only ON booking_recovery_cases;
CREATE TRIGGER booking_recovery_cases_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_recovery_cases
  FOR EACH ROW EXECUTE FUNCTION booking_recovery_tables_engine_only();
DROP TRIGGER IF EXISTS booking_recovery_events_engine_only ON booking_recovery_events;
CREATE TRIGGER booking_recovery_events_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_recovery_events
  FOR EACH ROW EXECUTE FUNCTION booking_recovery_tables_engine_only();
DROP TRIGGER IF EXISTS booking_late_success_engine_only ON booking_late_payout_success_exceptions;
CREATE TRIGGER booking_late_success_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_late_payout_success_exceptions
  FOR EACH ROW EXECUTE FUNCTION booking_recovery_tables_engine_only();

CREATE OR REPLACE FUNCTION apply_booking_reversal_to_escrow() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_payment payments;
  v_contract booking_settlement_contracts;
  v_case booking_recovery_cases;
  v_customer_funds UUID;
  v_due_to UUID;
  v_due_from UUID;
  v_supplier_revenue UUID;
  v_recovery_receivable UUID;
  v_recovery_payable UUID;
  v_escrow BIGINT;
  v_released BIGINT;
  v_paid BIGINT;
  v_unpaid BIGINT;
  v_recoverable BIGINT;
  v_remaining BIGINT;
  v_customer_journal UUID;
  v_provider_journal UUID;
  v_lines JSONB := '[]'::JSONB;
  v_provider_lines JSONB := '[]'::JSONB;
  v_line INTEGER := 0;
  v_previous TEXT;
  v_previous_settlement TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;
  IF NOT FOUND OR v_payment.source_type <> 'booking' THEN RETURN NEW; END IF;
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE payment_id = v_payment.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_LEGACY_REVIEW_REQUIRED'; END IF;
  SELECT * INTO v_case FROM booking_recovery_cases
  WHERE payment_reversal_id = NEW.id;
  IF FOUND THEN RETURN NEW; END IF;

  v_escrow := LEAST(
    NEW.amount_minor,
    GREATEST(wallet_account_balance_minor(v_contract.escrow_account_id), 0)
  );
  v_remaining := NEW.amount_minor - v_escrow;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_released
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'supplier' AND state = 'final';
  SELECT COALESCE(sum(item.amount_minor), 0) INTO v_paid
  FROM booking_supplier_payout_items item
  JOIN payouts payout ON payout.id = item.payout_id
  WHERE item.settlement_contract_id = v_contract.id AND payout.state = 'succeeded';
  v_paid := LEAST(v_paid, v_remaining);
  v_unpaid := LEAST(GREATEST(v_released - v_paid, 0), v_remaining - v_paid);
  v_recoverable := GREATEST(v_remaining - v_unpaid, 0);

  v_customer_funds := ensure_wallet_system_account(
    v_contract.organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  IF v_escrow > 0 THEN
    v_line := v_line + 1;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_contract.escrow_account_id, 'line_number', v_line,
      'side', 'debit', 'amount_minor', v_escrow, 'memo', 'Reverse unreleased booking escrow'
    ));
  END IF;
  IF v_unpaid > 0 THEN
    v_due_to := ensure_booking_settlement_account(
      v_contract.organization_id, v_contract.provider_organization_id,
      v_payment.actor_id, 'interorganization_settlement_due_to', NEW.currency
    );
    v_line := v_line + 1;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_due_to, 'line_number', v_line, 'side', 'debit',
      'amount_minor', v_unpaid, 'memo', 'Reverse unpaid supplier allocation'
    ));
  END IF;
  IF v_recoverable > 0 THEN
    v_recovery_receivable := ensure_booking_settlement_account(
      v_contract.organization_id, v_contract.provider_organization_id,
      v_payment.actor_id, 'dispute_recovery_receivable', NEW.currency
    );
    v_line := v_line + 1;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_recovery_receivable, 'line_number', v_line,
      'side', 'debit', 'amount_minor', v_recoverable,
      'memo', 'Recognize post-payout supplier recovery'
    ));
  END IF;
  v_line := v_line + 1;
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_customer_funds, 'line_number', v_line, 'side', 'credit',
    'amount_minor', NEW.amount_minor, 'memo', 'Route provider reversal'
  ));
  v_customer_journal := post_wallet_journal(
    v_contract.organization_id, 'booking.reversal.classification',
    NEW.id::TEXT,
    'Classify provider reversal across escrow, payable, and recovery',
    v_lines
  );

  IF v_unpaid + v_recoverable > 0 THEN
    v_due_from := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.organization_id,
      v_payment.actor_id, 'interorganization_settlement_due_from', NEW.currency
    );
    v_supplier_revenue := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.organization_id,
      v_payment.actor_id,
      'supplier_booking_service_revenue', NEW.currency
    );
    v_provider_lines := jsonb_build_array(jsonb_build_object(
      'account_id', v_supplier_revenue, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_unpaid + v_recoverable, 'memo', 'Reverse supplier revenue'
    ));
    IF v_unpaid > 0 THEN
      v_provider_lines := v_provider_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_due_from, 'line_number', 2, 'side', 'credit',
        'amount_minor', v_unpaid, 'memo', 'Reverse unpaid settlement receivable'
      ));
    END IF;
    IF v_recoverable > 0 THEN
      v_recovery_payable := ensure_booking_settlement_account(
        v_contract.provider_organization_id, v_contract.organization_id,
        v_payment.actor_id, 'booking_recovery_payable', NEW.currency
      );
      v_provider_lines := v_provider_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_recovery_payable,
        'line_number', CASE WHEN v_unpaid > 0 THEN 3 ELSE 2 END,
        'side', 'credit', 'amount_minor', v_recoverable,
        'memo', 'Recognize post-payout recovery payable'
      ));
    END IF;
    v_provider_journal := post_booking_settlement_journal(
      v_contract.provider_organization_id, v_payment.actor_id, NEW.currency,
      'booking.reversal.provider', NEW.id::TEXT,
      'booking.reversal.provider:' || NEW.id::TEXT, v_contract.correlation_id,
      'Reverse supplier recognition and record recovery obligation', v_provider_lines
    );
  END IF;

  v_previous := current_setting('microfams.booking_recovery_engine', TRUE);
  v_previous_settlement := current_setting(
    'microfams.booking_settlement_engine', TRUE
  );
  PERFORM set_config('microfams.booking_recovery_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  IF v_escrow > 0 THEN
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id,
      journal_entry_id
    ) VALUES (
      v_contract.organization_id, v_contract.provider_organization_id,
      v_contract.id, 'reversal', 'final', v_escrow, NEW.currency,
      'payment_reversal', NEW.id, v_customer_journal
    ) ON CONFLICT (
      settlement_contract_id, allocation_type, source_type, source_id
    ) DO NOTHING;
  END IF;
  INSERT INTO booking_recovery_cases(
    organization_id, provider_organization_id, settlement_contract_id,
    payment_reversal_id, payout_id, currency, reversed_amount_minor,
    escrow_recovered_minor, unpaid_compensated_minor, recoverable_amount_minor,
    state, reason_code, correlation_id, customer_journal_entry_id,
    provider_journal_entry_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    NEW.id, (
      SELECT item.payout_id FROM booking_supplier_payout_items item
      JOIN payouts payout ON payout.id = item.payout_id
      WHERE item.settlement_contract_id = v_contract.id AND payout.state = 'succeeded'
      ORDER BY payout.terminal_at DESC LIMIT 1
    ), NEW.currency, NEW.amount_minor, v_escrow, v_unpaid, v_recoverable,
    CASE WHEN v_recoverable > 0 THEN 'open' ELSE 'closed' END,
    'provider_reversal', v_contract.correlation_id, v_customer_journal,
    v_provider_journal
  ) RETURNING * INTO v_case;
  INSERT INTO booking_recovery_events(
    organization_id, recovery_case_id, event_type, amount_minor, currency,
    evidence_snapshot, correlation_id
  ) VALUES (
    v_contract.organization_id, v_case.id, 'reversal_classified',
    NEW.amount_minor, NEW.currency,
    jsonb_build_object(
      'payment_reversal_id', NEW.id, 'escrow_recovered_minor', v_escrow,
      'unpaid_compensated_minor', v_unpaid,
      'recoverable_amount_minor', v_recoverable,
      'original_payment_id', NEW.payment_id
    ), v_contract.correlation_id
  );
  IF v_recoverable > 0 THEN
    INSERT INTO booking_recovery_events(
      organization_id, recovery_case_id, event_type, amount_minor, currency,
      evidence_snapshot, correlation_id
    ) VALUES (
      v_contract.organization_id, v_case.id, 'recovery_required',
      v_recoverable, NEW.currency,
      jsonb_build_object('automatic_wallet_debit_permitted', FALSE),
      v_contract.correlation_id
    );
  END IF;
  UPDATE booking_settlement_contracts SET
    state = 'reversed', updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config(
    'microfams.booking_recovery_engine', COALESCE(v_previous, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine',
    COALESCE(v_previous_settlement, ''), TRUE
  );
  RETURN NEW;
END;
$$;

ALTER TABLE booking_recovery_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_recovery_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_late_payout_success_exceptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY booking_recovery_case_tenant_read ON booking_recovery_cases
  FOR SELECT USING (
    has_active_organization_membership(organization_id)
    OR has_active_organization_membership(provider_organization_id)
  );
CREATE POLICY booking_recovery_event_tenant_read ON booking_recovery_events
  FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY booking_late_success_tenant_read ON booking_late_payout_success_exceptions
  FOR SELECT USING (has_active_organization_membership(organization_id));

REVOKE ALL ON booking_recovery_cases, booking_recovery_events,
  booking_late_payout_success_exceptions FROM anon, authenticated;
GRANT SELECT ON booking_recovery_cases, booking_recovery_events,
  booking_late_payout_success_exceptions TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_recovery_cases, booking_recovery_events,
  booking_late_payout_success_exceptions FROM service_role;
REVOKE ALL ON FUNCTION booking_recovery_tables_engine_only()
  FROM PUBLIC, anon, authenticated, service_role;
