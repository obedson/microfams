-- BS-01/BS-02/BS-05/BS-09/BS-11: booking escrow custody foundation.

INSERT INTO feature_flags(key, domain, description, default_enabled, failure_mode, risk) VALUES
  ('booking.settlements.create', 'booking', 'Create new booking settlement obligations.', FALSE, 'closed', 'regulated'),
  ('booking.settlements.service_existing', 'booking', 'Service existing booking settlement obligations.', TRUE, 'open', 'regulated'),
  ('booking.disputes.open', 'booking', 'Open new booking disputes.', FALSE, 'closed', 'regulated'),
  ('booking.disputes.service_existing', 'booking', 'Service existing booking disputes.', TRUE, 'open', 'regulated')
ON CONFLICT (key) DO UPDATE SET
  domain = EXCLUDED.domain,
  description = EXCLUDED.description,
  default_enabled = EXCLUDED.default_enabled,
  failure_mode = EXCLUDED.failure_mode,
  risk = EXCLUDED.risk,
  updated_at = NOW();

INSERT INTO financial_account_purpose_rules(
  purpose, account_class, normal_side, allowed_owner_types, is_control
) VALUES
  ('supplier_settlement_payable', 'liability', 'credit', ARRAY['organization','provider','system'], TRUE),
  ('interorganization_settlement_due_to', 'liability', 'credit', ARRAY['organization','provider','system'], TRUE),
  ('interorganization_settlement_due_from', 'asset', 'debit', ARRAY['organization','provider','system'], TRUE),
  ('platform_fee_payable', 'liability', 'credit', ARRAY['organization','system'], TRUE),
  ('supplier_booking_service_revenue', 'revenue', 'credit', ARRAY['organization','provider'], FALSE),
  ('platform_booking_fee_revenue', 'revenue', 'credit', ARRAY['organization','system'], FALSE),
  ('dispute_recovery_receivable', 'asset', 'debit', ARRAY['organization','provider','system'], TRUE),
  ('dispute_chargeback_loss', 'expense', 'debit', ARRAY['organization','system'], FALSE)
ON CONFLICT (purpose) DO UPDATE SET
  account_class = EXCLUDED.account_class,
  normal_side = EXCLUDED.normal_side,
  allowed_owner_types = EXCLUDED.allowed_owner_types,
  is_control = EXCLUDED.is_control;

CREATE TABLE IF NOT EXISTS booking_settlement_contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL UNIQUE REFERENCES bookings(id),
  payment_id UUID NOT NULL UNIQUE REFERENCES payments(id),
  escrow_account_id UUID UNIQUE REFERENCES financial_accounts(id),
  payment_capture_journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
  escrow_funding_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  gross_amount_minor BIGINT NOT NULL CHECK (gross_amount_minor > 0),
  state TEXT NOT NULL DEFAULT 'funding' CHECK (state IN (
    'funding', 'funded', 'partially_refunded', 'refunded', 'reversed',
    'completed_pending_window', 'disputed', 'eligible', 'settled', 'manual_review'
  )),
  policy_version TEXT NOT NULL DEFAULT 'BS-2026-07-28',
  policy_snapshot JSONB NOT NULL CHECK (jsonb_typeof(policy_snapshot) = 'object'),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  funded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT booking_settlement_distinct_tenants CHECK (organization_id <> provider_organization_id),
  CONSTRAINT booking_settlement_funding_shape CHECK (
    (state = 'funding' AND escrow_account_id IS NULL AND escrow_funding_journal_entry_id IS NULL AND funded_at IS NULL)
    OR
    (state <> 'funding' AND escrow_account_id IS NOT NULL AND escrow_funding_journal_entry_id IS NOT NULL AND funded_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_booking_settlement_customer
  ON booking_settlement_contracts(organization_id, state, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_settlement_provider
  ON booking_settlement_contracts(provider_organization_id, state, created_at DESC);

CREATE TABLE IF NOT EXISTS booking_settlement_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  allocation_type TEXT NOT NULL CHECK (allocation_type IN (
    'refund', 'reversal', 'contested', 'supplier', 'platform_fee'
  )),
  state TEXT NOT NULL CHECK (state IN ('reserved', 'final', 'released')),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  source_type TEXT NOT NULL CHECK (source_type IN (
    'payment_refund', 'payment_reversal', 'booking_dispute', 'supplier_release', 'platform_fee'
  )),
  source_id UUID NOT NULL,
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (settlement_contract_id, allocation_type, source_type, source_id)
);

CREATE INDEX IF NOT EXISTS idx_booking_settlement_allocations_contract
  ON booking_settlement_allocations(settlement_contract_id, allocation_type, state);

CREATE TABLE IF NOT EXISTS booking_settlement_legacy_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL REFERENCES bookings(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  payment_capture_journal_entry_id UUID REFERENCES journal_entries(id),
  gross_amount_minor BIGINT NOT NULL CHECK (gross_amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  evidence_snapshot JSONB NOT NULL CHECK (jsonb_typeof(evidence_snapshot) = 'object'),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'investigating', 'resolved')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  UNIQUE (booking_id),
  UNIQUE (payment_id),
  CHECK ((state = 'resolved') = (resolved_at IS NOT NULL))
);

CREATE OR REPLACE FUNCTION protect_booking_settlement_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF current_setting('microfams.booking_settlement_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking settlement records can only be changed by the settlement engine';
END;
$$;

DROP TRIGGER IF EXISTS booking_settlement_contracts_engine_only ON booking_settlement_contracts;
CREATE TRIGGER booking_settlement_contracts_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_contracts
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_records();
DROP TRIGGER IF EXISTS booking_settlement_allocations_engine_only ON booking_settlement_allocations;
CREATE TRIGGER booking_settlement_allocations_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_allocations
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_records();
DROP TRIGGER IF EXISTS booking_settlement_legacy_reviews_engine_only ON booking_settlement_legacy_reviews;
CREATE TRIGGER booking_settlement_legacy_reviews_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_legacy_reviews
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_records();

CREATE OR REPLACE FUNCTION ensure_booking_escrow_account(
  p_contract_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_currency TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
  v_code TEXT;
  v_key TEXT;
  v_hash TEXT;
BEGIN
  IF upper(p_currency) <> 'NGN' THEN
    RAISE EXCEPTION 'Booking settlement currency is unsupported';
  END IF;
  v_code := 'BKG.ESCROW.' || upper(substr(md5(p_contract_id::TEXT), 1, 24));
  v_key := 'booking-settlement:' || p_contract_id::TEXT;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_contract_id, p_organization_id, p_actor_id, upper(p_currency), v_code
  ), 'UTF8'), 'sha256'), 'hex');

  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency,
    owner_type, owner_id, is_control, status, created_by, purpose,
    effective_from, provisioning_key, provisioning_hash
  ) VALUES (
    p_organization_id, v_code, 'Booking funds held in escrow', 'liability', 'credit',
    upper(p_currency), 'escrow_contract', p_contract_id, TRUE, 'active', p_actor_id,
    'escrow_funds_held', CURRENT_DATE, v_key, v_hash
  )
  ON CONFLICT (organization_id, code, currency) DO NOTHING;

  SELECT id INTO v_account_id
  FROM financial_accounts
  WHERE organization_id = p_organization_id
    AND code = v_code
    AND currency = upper(p_currency)
    AND owner_type = 'escrow_contract'
    AND owner_id = p_contract_id
    AND purpose = 'escrow_funds_held'
    AND account_class = 'liability'
    AND normal_side = 'credit'
    AND status = 'active';
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Booking escrow account conflicts with the approved account mapping';
  END IF;
  RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION fund_booking_settlement_after_payment() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_booking bookings;
  v_property properties;
  v_contract booking_settlement_contracts;
  v_contract_id UUID;
  v_escrow_account UUID;
  v_customer_funds_account UUID;
  v_journal UUID;
  v_lines JSONB;
  v_hash TEXT;
  v_previous TEXT;
BEGIN
  IF NEW.source_type <> 'booking' OR NEW.state <> 'succeeded'
    OR OLD.state IS NOT DISTINCT FROM NEW.state THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('booking-settlement:' || NEW.source_id::TEXT, 0));
  SELECT * INTO v_booking FROM bookings WHERE id = NEW.source_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_BOOKING_NOT_FOUND'; END IF;
  SELECT * INTO v_property FROM properties WHERE id = v_booking.property_id;
  IF NOT FOUND
    OR v_booking.organization_id <> NEW.organization_id
    OR v_booking.provider_organization_id IS NULL
    OR v_property.organization_id <> v_booking.provider_organization_id
    OR v_booking.farmer_id IS DISTINCT FROM NEW.payer_id
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_OWNERSHIP_MISMATCH'; END IF;
  IF v_booking.organization_id = v_booking.provider_organization_id THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_REQUIRES_DISTINCT_TENANTS';
  END IF;
  IF v_booking.total_amount * 100 <> trunc(v_booking.total_amount * 100)
    OR (v_booking.total_amount * 100)::BIGINT <> NEW.amount_minor
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_AMOUNT_MISMATCH'; END IF;
  IF NEW.success_journal_entry_id IS NULL THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_CAPTURE_JOURNAL_REQUIRED';
  END IF;

  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE payment_id = NEW.id OR booking_id = v_booking.id;
  IF v_contract.id IS NOT NULL THEN
    IF v_contract.payment_id <> NEW.id
      OR v_contract.gross_amount_minor <> NEW.amount_minor
      OR v_contract.currency <> NEW.currency
    THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REPLAY_CONFLICT'; END IF;
    RETURN NEW;
  END IF;

  v_contract_id := gen_random_uuid();
  v_hash := encode(digest(convert_to(concat_ws('|',
    v_booking.organization_id, v_booking.provider_organization_id, v_booking.id,
    NEW.id, NEW.currency, NEW.amount_minor, NEW.correlation_id, 'BS-2026-07-28'
  ), 'UTF8'), 'sha256'), 'hex');
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_settlement_contracts(
    id, organization_id, provider_organization_id, booking_id, payment_id,
    payment_capture_journal_entry_id, currency, gross_amount_minor, state,
    policy_version, policy_snapshot, request_hash, correlation_id
  ) VALUES (
    v_contract_id, v_booking.organization_id, v_booking.provider_organization_id,
    v_booking.id, NEW.id, NEW.success_journal_entry_id, NEW.currency, NEW.amount_minor,
    'funding', 'BS-2026-07-28',
    jsonb_build_object(
      'version', 'BS-2026-07-28',
      'default_dispute_window_hours', 48,
      'default_response_period_days', 3,
      'platform_fee_basis_points', 0,
      'payment_provider', NEW.provider_name,
      'payment_environment', NEW.provider_environment,
      'captured_at', NOW()
    ),
    v_hash, NEW.correlation_id
  );

  v_escrow_account := ensure_booking_escrow_account(
    v_contract_id, v_booking.organization_id, NEW.actor_id, NEW.currency
  );
  v_customer_funds_account := ensure_wallet_system_account(
    NEW.organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_customer_funds_account, 'line_number', 1, 'side', 'debit',
      'amount_minor', NEW.amount_minor, 'memo', 'Allocate captured booking funds'
    ),
    jsonb_build_object(
      'account_id', v_escrow_account, 'line_number', 2, 'side', 'credit',
      'amount_minor', NEW.amount_minor, 'memo', 'Hold booking funds in escrow'
    )
  );
  v_journal := post_wallet_journal(
    NEW.organization_id, 'booking.escrow.funding', NEW.id::TEXT,
    'Hold captured booking payment in escrow', v_lines
  );
  UPDATE booking_settlement_contracts SET
    escrow_account_id = v_escrow_account,
    escrow_funding_journal_entry_id = v_journal,
    state = 'funded',
    funded_at = NOW(),
    updated_at = NOW()
  WHERE id = v_contract_id;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES
    (
      v_booking.organization_id, NEW.actor_id, 'booking.settlement.funded',
      'booking_settlement', v_contract_id::TEXT,
      jsonb_build_object(
        'booking_id', v_booking.id,
        'payment_id', NEW.id,
        'amount_minor', NEW.amount_minor,
        'currency', NEW.currency,
        'policy_version', 'BS-2026-07-28',
        'correlation_id', NEW.correlation_id
      )
    ),
    (
      v_booking.provider_organization_id, NEW.actor_id, 'booking.settlement.funded',
      'booking_settlement', v_contract_id::TEXT,
      jsonb_build_object(
        'booking_id', v_booking.id,
        'customer_organization_id', v_booking.organization_id,
        'amount_minor', NEW.amount_minor,
        'currency', NEW.currency,
        'policy_version', 'BS-2026-07-28',
        'correlation_id', NEW.correlation_id
      )
    );
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fund_booking_settlement_on_payment_success ON payments;
CREATE TRIGGER fund_booking_settlement_on_payment_success
  AFTER UPDATE OF state ON payments
  FOR EACH ROW
  WHEN (NEW.source_type = 'booking' AND NEW.state = 'succeeded' AND OLD.state IS DISTINCT FROM NEW.state)
  EXECUTE FUNCTION fund_booking_settlement_after_payment();

CREATE OR REPLACE FUNCTION apply_booking_refund_to_escrow() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payment payments;
  v_contract booking_settlement_contracts;
  v_customer_funds_account UUID;
  v_journal UUID;
  v_lines JSONB;
  v_refunded BIGINT;
  v_previous TEXT;
BEGIN
  IF NEW.state <> 'succeeded' OR OLD.state IS NOT DISTINCT FROM NEW.state THEN RETURN NEW; END IF;
  SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;
  IF NOT FOUND OR v_payment.source_type <> 'booking' THEN RETURN NEW; END IF;
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE payment_id = v_payment.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_LEGACY_REVIEW_REQUIRED'; END IF;
  IF wallet_account_balance_minor(v_contract.escrow_account_id) < NEW.amount_minor THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_ESCROW_INSUFFICIENT'; END IF;

  v_customer_funds_account := ensure_wallet_system_account(
    v_payment.organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_contract.escrow_account_id, 'line_number', 1, 'side', 'debit',
      'amount_minor', NEW.amount_minor, 'memo', 'Release booking escrow for refund'
    ),
    jsonb_build_object(
      'account_id', v_customer_funds_account, 'line_number', 2, 'side', 'credit',
      'amount_minor', NEW.amount_minor, 'memo', 'Route booking refund to payment engine'
    )
  );
  v_journal := post_wallet_journal(
    v_payment.organization_id, 'booking.escrow.refund', NEW.id::TEXT,
    'Release booking escrow for successful refund', v_lines
  );

  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_settlement_allocations(
    organization_id, provider_organization_id, settlement_contract_id,
    allocation_type, state, amount_minor, currency, source_type, source_id,
    journal_entry_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'refund', 'final', NEW.amount_minor, NEW.currency, 'payment_refund', NEW.id, v_journal
  ) ON CONFLICT (settlement_contract_id, allocation_type, source_type, source_id) DO NOTHING;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund'
    AND state = 'final';
  UPDATE booking_settlement_contracts SET
    state = CASE WHEN v_refunded = gross_amount_minor THEN 'refunded' ELSE 'partially_refunded' END,
    updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS apply_booking_refund_escrow_on_success ON payment_refunds;
CREATE TRIGGER apply_booking_refund_escrow_on_success
  AFTER UPDATE OF state ON payment_refunds
  FOR EACH ROW
  WHEN (NEW.state = 'succeeded' AND OLD.state IS DISTINCT FROM NEW.state)
  EXECUTE FUNCTION apply_booking_refund_to_escrow();

CREATE OR REPLACE FUNCTION apply_booking_reversal_to_escrow() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payment payments;
  v_contract booking_settlement_contracts;
  v_customer_funds_account UUID;
  v_journal UUID;
  v_lines JSONB;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;
  IF NOT FOUND OR v_payment.source_type <> 'booking' THEN RETURN NEW; END IF;
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE payment_id = v_payment.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_LEGACY_REVIEW_REQUIRED'; END IF;
  IF wallet_account_balance_minor(v_contract.escrow_account_id) < NEW.amount_minor THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_ESCROW_INSUFFICIENT'; END IF;

  v_customer_funds_account := ensure_wallet_system_account(
    v_payment.organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_contract.escrow_account_id, 'line_number', 1, 'side', 'debit',
      'amount_minor', NEW.amount_minor, 'memo', 'Release booking escrow for reversal'
    ),
    jsonb_build_object(
      'account_id', v_customer_funds_account, 'line_number', 2, 'side', 'credit',
      'amount_minor', NEW.amount_minor, 'memo', 'Route booking reversal to payment engine'
    )
  );
  v_journal := post_wallet_journal(
    v_payment.organization_id, 'booking.escrow.reversal', NEW.id::TEXT,
    'Release booking escrow for provider reversal', v_lines
  );

  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_settlement_allocations(
    organization_id, provider_organization_id, settlement_contract_id,
    allocation_type, state, amount_minor, currency, source_type, source_id,
    journal_entry_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'reversal', 'final', NEW.amount_minor, NEW.currency, 'payment_reversal', NEW.id, v_journal
  ) ON CONFLICT (settlement_contract_id, allocation_type, source_type, source_id) DO NOTHING;
  UPDATE booking_settlement_contracts SET state = 'reversed', updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS apply_booking_reversal_escrow_on_insert ON payment_reversals;
CREATE TRIGGER apply_booking_reversal_escrow_on_insert
  AFTER INSERT ON payment_reversals
  FOR EACH ROW EXECUTE FUNCTION apply_booking_reversal_to_escrow();

DO $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_settlement_legacy_reviews(
    organization_id, provider_organization_id, booking_id, payment_id,
    payment_capture_journal_entry_id, gross_amount_minor, currency,
    reason_code, evidence_snapshot
  )
  SELECT
    b.organization_id,
    b.provider_organization_id,
    b.id,
    p.id,
    p.success_journal_entry_id,
    p.amount_minor,
    p.currency,
    'pre_bs01_paid_booking',
    jsonb_build_object(
      'payment_state', p.state,
      'booking_state', b.status,
      'payment_status', b.payment_status,
      'captured_at', p.terminal_at,
      'inventoried_at', NOW()
    )
  FROM payments p
  JOIN bookings b ON b.id = p.source_id
  WHERE p.source_type = 'booking'
    AND p.state IN ('succeeded', 'partially_refunded', 'refunded')
    AND b.organization_id = p.organization_id
    AND b.provider_organization_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM booking_settlement_contracts c
      WHERE c.payment_id = p.id OR c.booking_id = b.id
    )
  ON CONFLICT DO NOTHING;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
END;
$$;

ALTER TABLE booking_settlement_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_settlement_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_settlement_legacy_reviews ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON booking_settlement_contracts, booking_settlement_allocations,
  booking_settlement_legacy_reviews FROM anon, authenticated;
GRANT SELECT ON booking_settlement_contracts, booking_settlement_allocations,
  booking_settlement_legacy_reviews TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_settlement_contracts,
  booking_settlement_allocations, booking_settlement_legacy_reviews FROM service_role;

REVOKE ALL ON FUNCTION protect_booking_settlement_records() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION ensure_booking_escrow_account(UUID, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION fund_booking_settlement_after_payment() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION apply_booking_refund_to_escrow() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION apply_booking_reversal_to_escrow() FROM PUBLIC, anon, authenticated, service_role;

DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'booking_settlement_contracts',
    'booking_settlement_allocations',
    'booking_settlement_legacy_reviews'
  ] LOOP
    IF has_table_privilege('service_role', v_table, 'INSERT')
      OR has_table_privilege('service_role', v_table, 'UPDATE')
      OR has_table_privilege('service_role', v_table, 'DELETE')
    THEN RAISE EXCEPTION 'service_role has direct DML privilege on %', v_table; END IF;
    IF NOT has_table_privilege('service_role', v_table, 'SELECT')
    THEN RAISE EXCEPTION 'service_role cannot service existing % records', v_table; END IF;
  END LOOP;
END;
$$;
