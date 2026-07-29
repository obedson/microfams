-- BS-07: dispute review, maker-checker resolution, recoverable servicing,
-- pending-refund reservations, and cumulative partial settlement.

SET search_path = public, extensions;

ALTER TABLE booking_settlement_contracts
  DROP CONSTRAINT IF EXISTS booking_settlement_contracts_state_check;
ALTER TABLE booking_settlement_contracts
  ADD CONSTRAINT booking_settlement_contracts_state_check CHECK (state IN (
    'funding', 'funded', 'partially_refunded', 'refunded', 'reversed',
    'completed_pending_window', 'disputed', 'eligible', 'partially_settled',
    'settled', 'manual_review'
  ));

CREATE TABLE IF NOT EXISTS booking_dispute_response_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  version INTEGER NOT NULL CHECK (version > 0),
  response_period_days INTEGER NOT NULL CHECK (response_period_days BETWEEN 1 AND 14),
  status TEXT NOT NULL DEFAULT 'pending_approval'
    CHECK (status IN ('pending_approval', 'active', 'retired', 'rejected')),
  effective_from TIMESTAMPTZ NOT NULL,
  effective_until TIMESTAMPTZ,
  change_reason TEXT NOT NULL CHECK (length(btrim(change_reason)) BETWEEN 10 AND 500),
  created_by UUID REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  approved_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  decision_idempotency_key TEXT,
  decision_request_hash VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, version),
  UNIQUE (organization_id, idempotency_key),
  CHECK (effective_until IS NULL OR effective_until > effective_from),
  CHECK (approved_by IS NULL OR created_by IS NULL OR approved_by <> created_by)
);
CREATE INDEX IF NOT EXISTS idx_booking_dispute_response_rule_lookup
  ON booking_dispute_response_rules(organization_id, status, effective_from DESC);

CREATE TABLE IF NOT EXISTS booking_dispute_resolution_proposals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  customer_refund_minor BIGINT NOT NULL CHECK (customer_refund_minor >= 0),
  supplier_release_minor BIGINT NOT NULL CHECK (supplier_release_minor >= 0),
  platform_fee_minor BIGINT NOT NULL CHECK (platform_fee_minor >= 0),
  recoverable_amount_minor BIGINT NOT NULL CHECK (recoverable_amount_minor >= 0),
  loss_amount_minor BIGINT NOT NULL CHECK (loss_amount_minor >= 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 20 AND 2000),
  evidence_ids UUID[] NOT NULL DEFAULT '{}',
  accounting_preview JSONB NOT NULL CHECK (jsonb_typeof(accounting_preview) = 'object'),
  state TEXT NOT NULL DEFAULT 'pending_approval'
    CHECK (state IN ('pending_approval', 'approved', 'rejected')),
  proposed_by_organization_id UUID NOT NULL REFERENCES organizations(id),
  proposed_by UUID NOT NULL REFERENCES users(id),
  decided_by UUID REFERENCES users(id),
  decision_reason TEXT CHECK (
    decision_reason IS NULL OR length(btrim(decision_reason)) BETWEEN 10 AND 1000
  ),
  decision_idempotency_key TEXT,
  decision_request_hash VARCHAR(64),
  decided_at TIMESTAMPTZ,
  refund_id UUID REFERENCES payment_refunds(id),
  release_id UUID,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (dispute_id, id),
  CHECK (
    customer_refund_minor + supplier_release_minor + platform_fee_minor
      + recoverable_amount_minor + loss_amount_minor > 0
  ),
  CHECK ((state = 'pending_approval') = (decided_at IS NULL)),
  CHECK (decided_by IS NULL OR proposed_by <> decided_by)
);
CREATE INDEX IF NOT EXISTS idx_booking_dispute_resolution_pending
  ON booking_dispute_resolution_proposals(organization_id, state, created_at);

CREATE TABLE IF NOT EXISTS booking_dispute_resolution_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  proposal_id UUID NOT NULL REFERENCES booking_dispute_resolution_proposals(id),
  allocation_type TEXT NOT NULL CHECK (allocation_type IN (
    'customer_refund', 'supplier_release', 'platform_fee', 'recoverable', 'loss'
  )),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'proposed'
    CHECK (state IN ('proposed', 'approved', 'rejected')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (proposal_id, allocation_type)
);

CREATE TABLE IF NOT EXISTS booking_dispute_recovery_commands (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  proposal_id UUID NOT NULL REFERENCES booking_dispute_resolution_proposals(id),
  recovery_type TEXT NOT NULL CHECK (recovery_type IN ('recoverable', 'loss')),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'created'
    CHECK (state IN ('created', 'processing', 'posted', 'failed', 'cancelled')),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 20 AND 2000),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (proposal_id, recovery_type),
  UNIQUE (organization_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS booking_dispute_notices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  recipient_organization_id UUID NOT NULL REFERENCES organizations(id),
  notice_type TEXT NOT NULL CHECK (notice_type IN (
    'opened', 'response_deadline', 'resolution_proposed',
    'resolution_approved', 'resolution_rejected', 'withdrawn', 'closed'
  )),
  public_payload JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(public_payload) = 'object'),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'delivering', 'delivered', 'failed')),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivered_at TIMESTAMPTZ,
  UNIQUE (recipient_organization_id, idempotency_key),
  CHECK (recipient_organization_id IN (organization_id, provider_organization_id)),
  CHECK ((state = 'delivered') = (delivered_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_booking_dispute_notices_delivery
  ON booking_dispute_notices(state, created_at) WHERE state IN ('queued', 'failed');

CREATE TABLE IF NOT EXISTS booking_settlement_releases (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  release_kind TEXT NOT NULL CHECK (release_kind IN ('ordinary', 'dispute_resolution')),
  source_id UUID NOT NULL,
  release_base_minor BIGINT NOT NULL CHECK (release_base_minor > 0),
  supplier_amount_minor BIGINT NOT NULL CHECK (supplier_amount_minor >= 0),
  platform_fee_amount_minor BIGINT NOT NULL CHECK (platform_fee_amount_minor >= 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  customer_journal_entry_id UUID NOT NULL REFERENCES journal_entries(id),
  provider_journal_entry_id UUID REFERENCES journal_entries(id),
  platform_journal_entry_id UUID REFERENCES journal_entries(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (settlement_contract_id, release_kind, source_id),
  CHECK (supplier_amount_minor + platform_fee_amount_minor = release_base_minor)
);
CREATE INDEX IF NOT EXISTS idx_booking_settlement_release_contract
  ON booking_settlement_releases(settlement_contract_id, created_at);

CREATE OR REPLACE FUNCTION protect_booking_dispute_resolution_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_dispute_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking dispute resolution records can only be changed by the dispute engine';
END;
$$;

CREATE OR REPLACE FUNCTION protect_booking_dispute_resolution_history() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Booking dispute resolution history is append-only';
END;
$$;

CREATE OR REPLACE FUNCTION protect_booking_settlement_release_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_settlement_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking settlement releases can only be changed by the settlement engine';
END;
$$;

DROP TRIGGER IF EXISTS booking_dispute_response_rules_engine_only
  ON booking_dispute_response_rules;
CREATE TRIGGER booking_dispute_response_rules_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_dispute_response_rules
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_resolution_records();
DROP TRIGGER IF EXISTS booking_dispute_resolution_proposals_engine_only
  ON booking_dispute_resolution_proposals;
CREATE TRIGGER booking_dispute_resolution_proposals_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_dispute_resolution_proposals
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_resolution_records();
DROP TRIGGER IF EXISTS booking_dispute_resolution_allocations_engine_only
  ON booking_dispute_resolution_allocations;
CREATE TRIGGER booking_dispute_resolution_allocations_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_dispute_resolution_allocations
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_resolution_records();
DROP TRIGGER IF EXISTS booking_dispute_recovery_commands_engine_only
  ON booking_dispute_recovery_commands;
CREATE TRIGGER booking_dispute_recovery_commands_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_dispute_recovery_commands
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_resolution_records();
DROP TRIGGER IF EXISTS booking_dispute_notices_engine_only ON booking_dispute_notices;
CREATE TRIGGER booking_dispute_notices_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_dispute_notices
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_resolution_records();
DROP TRIGGER IF EXISTS booking_settlement_releases_engine_only ON booking_settlement_releases;
CREATE TRIGGER booking_settlement_releases_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_releases
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_release_records();

DO $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  INSERT INTO booking_dispute_response_rules(
    organization_id, version, response_period_days, status, effective_from,
    change_reason, idempotency_key, request_hash
  )
  SELECT
    organization.id, 1, 3, 'active', '-infinity',
    'Approved BS-07 default response period.', 'default-bs07-response-rule',
    encode(digest(convert_to(
      organization.id::TEXT || '|BS07|1|3', 'UTF8'
    ), 'sha256'), 'hex')
  FROM organizations AS organization
  ON CONFLICT (organization_id, version) DO NOTHING;
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION provision_default_booking_dispute_response_rule() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  INSERT INTO booking_dispute_response_rules(
    organization_id, version, response_period_days, status, effective_from,
    change_reason, idempotency_key, request_hash
  ) VALUES (
    NEW.id, 1, 3, 'active', '-infinity',
    'Approved BS-07 default response period.', 'default-bs07-response-rule',
    encode(digest(convert_to(NEW.id::TEXT || '|BS07|1|3', 'UTF8'), 'sha256'), 'hex')
  ) ON CONFLICT (organization_id, version) DO NOTHING;
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS provision_default_booking_dispute_response_rule_trigger
  ON organizations;
CREATE TRIGGER provision_default_booking_dispute_response_rule_trigger
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION provision_default_booking_dispute_response_rule();

CREATE OR REPLACE FUNCTION snapshot_booking_dispute_response_rule() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rule booking_dispute_response_rules;
BEGIN
  SELECT * INTO v_rule
  FROM booking_dispute_response_rules
  WHERE organization_id = NEW.organization_id
    AND status = 'active'
    AND effective_from <= NOW()
    AND (effective_until IS NULL OR effective_until > NOW())
  ORDER BY effective_from DESC, version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_UNAVAILABLE'; END IF;
  NEW.response_deadline_at := NOW() + make_interval(days => v_rule.response_period_days);
  NEW.rule_snapshot := COALESCE(NEW.rule_snapshot, '{}'::JSONB) || jsonb_build_object(
    'response_rule_id', v_rule.id,
    'response_rule_version', v_rule.version,
    'response_period_days', v_rule.response_period_days
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_disputes_response_rule_snapshot ON booking_disputes;
CREATE TRIGGER booking_disputes_response_rule_snapshot
  BEFORE INSERT ON booking_disputes
  FOR EACH ROW EXECUTE FUNCTION snapshot_booking_dispute_response_rule();

CREATE OR REPLACE FUNCTION queue_booking_dispute_opened_notices() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO booking_dispute_notices(
    organization_id, provider_organization_id, dispute_id,
    recipient_organization_id, notice_type, public_payload,
    idempotency_key, correlation_id
  ) VALUES
    (
      NEW.organization_id, NEW.provider_organization_id, NEW.id,
      NEW.organization_id, 'opened',
      jsonb_build_object(
        'state', NEW.state, 'response_deadline_at', NEW.response_deadline_at,
        'contested_amount_minor', NEW.contested_amount_minor, 'currency', NEW.currency
      ),
      'dispute-opened:' || NEW.id::TEXT || ':customer', NEW.correlation_id
    ),
    (
      NEW.organization_id, NEW.provider_organization_id, NEW.id,
      NEW.provider_organization_id, 'opened',
      jsonb_build_object(
        'state', NEW.state, 'response_deadline_at', NEW.response_deadline_at,
        'contested_amount_minor', NEW.contested_amount_minor, 'currency', NEW.currency
      ),
      'dispute-opened:' || NEW.id::TEXT || ':provider', NEW.correlation_id
    );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_disputes_queue_opened_notices ON booking_disputes;
CREATE TRIGGER booking_disputes_queue_opened_notices
  AFTER INSERT ON booking_disputes
  FOR EACH ROW EXECUTE FUNCTION queue_booking_dispute_opened_notices();

CREATE OR REPLACE FUNCTION reserve_booking_refund_allocation() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment payments;
  v_contract booking_settlement_contracts;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;
  IF NOT FOUND OR v_payment.source_type <> 'booking' THEN RETURN NEW; END IF;
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE payment_id = NEW.payment_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_settlement_allocations(
    organization_id, provider_organization_id, settlement_contract_id,
    allocation_type, state, amount_minor, currency, source_type, source_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'refund', 'reserved', NEW.amount_minor, NEW.currency, 'payment_refund', NEW.id
  ) ON CONFLICT (settlement_contract_id, allocation_type, source_type, source_id)
    DO NOTHING;
  INSERT INTO booking_settlement_holds(
    organization_id, provider_organization_id, settlement_contract_id,
    hold_type, amount_minor, currency, source_type, source_id, reason_code
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'refund', NEW.amount_minor, NEW.currency, 'payment_refund', NEW.id::TEXT,
    'refund_pending'
  ) ON CONFLICT (settlement_contract_id, hold_type, source_type, source_id)
    DO NOTHING;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS reserve_booking_refund_on_create ON payment_refunds;
CREATE TRIGGER reserve_booking_refund_on_create
  AFTER INSERT ON payment_refunds
  FOR EACH ROW EXECUTE FUNCTION reserve_booking_refund_allocation();

CREATE OR REPLACE FUNCTION release_failed_booking_refund_reservation() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_previous TEXT;
BEGIN
  IF NEW.state NOT IN ('failed', 'cancelled')
    OR OLD.state IS NOT DISTINCT FROM NEW.state THEN RETURN NEW; END IF;
  SELECT contract.* INTO v_contract
  FROM booking_settlement_contracts AS contract
  JOIN payments AS payment ON payment.id = contract.payment_id
  WHERE payment.id = NEW.payment_id AND payment.source_type = 'booking';
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  UPDATE booking_settlement_allocations
  SET state = 'released', updated_at = NOW()
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND source_type = 'payment_refund'
    AND source_id = NEW.id AND state = 'reserved';
  UPDATE booking_settlement_holds
  SET reason_code = CASE WHEN NEW.state = 'failed'
      THEN 'refund_failed_review' ELSE 'refund_cancelled_review' END
  WHERE settlement_contract_id = v_contract.id
    AND hold_type = 'refund' AND source_type = 'payment_refund'
    AND source_id = NEW.id::TEXT AND state = 'active';
  UPDATE booking_settlement_contracts
  SET state = 'manual_review', updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS release_failed_booking_refund_reservation_trigger
  ON payment_refunds;
CREATE TRIGGER release_failed_booking_refund_reservation_trigger
  AFTER UPDATE OF state ON payment_refunds
  FOR EACH ROW
  WHEN (NEW.state IN ('failed', 'cancelled') AND OLD.state IS DISTINCT FROM NEW.state)
  EXECUTE FUNCTION release_failed_booking_refund_reservation();

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
  v_released BIGINT;
  v_contested BIGINT;
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
  ) ON CONFLICT (settlement_contract_id, allocation_type, source_type, source_id)
    DO UPDATE SET state = 'final', journal_entry_id = EXCLUDED.journal_entry_id,
      updated_at = NOW();
  UPDATE booking_settlement_holds
  SET state = 'released', released_at = NOW()
  WHERE settlement_contract_id = v_contract.id
    AND hold_type = 'refund' AND source_type = 'payment_refund'
    AND source_id = NEW.id::TEXT AND state = 'active';

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_released
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  UPDATE booking_settlement_contracts SET
    state = CASE
      WHEN v_refunded = gross_amount_minor THEN 'refunded'
      WHEN v_refunded + v_released + v_contested = gross_amount_minor
        THEN 'partially_settled'
      ELSE 'partially_refunded'
    END,
    updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION apply_booking_release_allocation(
  p_contract_id UUID,
  p_actor_id UUID,
  p_release_id UUID,
  p_release_kind TEXT,
  p_source_id UUID,
  p_release_base_minor BIGINT,
  p_expected_platform_fee_minor BIGINT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_fee booking_fee_rules;
  v_existing booking_settlement_releases;
  v_hash TEXT;
  v_previous TEXT;
  v_prior_base BIGINT;
  v_prior_fee BIGINT;
  v_cumulative_fee BIGINT;
  v_fee_delta BIGINT;
  v_supplier_delta BIGINT;
  v_due_to_provider UUID;
  v_provider_due_from UUID;
  v_supplier_revenue UUID;
  v_platform_payable UUID;
  v_platform_due_from UUID;
  v_platform_revenue UUID;
  v_customer_journal UUID;
  v_provider_journal UUID;
  v_platform_journal UUID;
  v_supplier_allocation UUID;
  v_fee_allocation UUID;
  v_lines JSONB;
BEGIN
  IF p_contract_id IS NULL OR p_actor_id IS NULL OR p_release_id IS NULL
    OR p_source_id IS NULL OR p_correlation_id IS NULL
    OR p_release_kind NOT IN ('ordinary', 'dispute_resolution')
    OR COALESCE(p_release_base_minor, 0) <= 0
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 200
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REQUEST_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_contract_id, p_actor_id, p_release_kind, p_source_id,
    p_release_base_minor, COALESCE(p_expected_platform_fee_minor, -1)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_settlement_releases
  WHERE organization_id = (
      SELECT organization_id FROM booking_settlement_contracts WHERE id = p_contract_id
    )
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'release', to_jsonb(v_existing), 'idempotency_replay', TRUE
    );
  END IF;

  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE id = p_contract_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND'; END IF;
  SELECT * INTO v_fee FROM booking_fee_rules WHERE id = v_contract.fee_rule_id;
  IF NOT FOUND OR v_fee.status NOT IN ('active', 'retired')
    OR v_fee.currency <> v_contract.currency
  THEN RAISE EXCEPTION 'BOOKING_FEE_RULE_UNAVAILABLE'; END IF;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_prior_base
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_prior_fee
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'platform_fee' AND state = 'final';
  v_cumulative_fee := calculate_booking_fee_minor(
    v_prior_base + p_release_base_minor,
    v_fee.fixed_amount_minor, v_fee.basis_points,
    v_fee.minimum_amount_minor, v_fee.maximum_amount_minor
  );
  v_fee_delta := greatest(v_cumulative_fee - v_prior_fee, 0);
  v_fee_delta := least(v_fee_delta, p_release_base_minor);
  IF p_expected_platform_fee_minor IS NOT NULL
    AND p_expected_platform_fee_minor <> v_fee_delta
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_PLATFORM_FEE_MISMATCH'; END IF;
  v_supplier_delta := p_release_base_minor - v_fee_delta;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_contract.escrow_account_id, 'line_number', 1,
      'side', 'debit', 'amount_minor', p_release_base_minor,
      'memo', 'Release approved booking escrow'
    )
  );
  IF v_supplier_delta > 0 THEN
    v_due_to_provider := ensure_booking_settlement_account(
      v_contract.organization_id, v_contract.provider_organization_id, p_actor_id,
      'interorganization_settlement_due_to', v_contract.currency
    );
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_due_to_provider, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_supplier_delta, 'memo', 'Supplier proceeds due'
    ));
  END IF;
  IF v_fee_delta > 0 THEN
    IF NOT EXISTS (
      SELECT 1 FROM organizations
      WHERE id = v_fee.beneficiary_organization_id AND status = 'active'
    ) THEN RAISE EXCEPTION 'BOOKING_FEE_BENEFICIARY_INVALID'; END IF;
    v_platform_payable := ensure_booking_settlement_account(
      v_contract.organization_id, v_fee.beneficiary_organization_id, p_actor_id,
      'platform_fee_payable', v_contract.currency
    );
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_platform_payable, 'line_number', 3, 'side', 'credit',
      'amount_minor', v_fee_delta, 'memo', 'Platform booking fee due'
    ));
  END IF;
  v_customer_journal := post_booking_settlement_journal(
    v_contract.organization_id, p_actor_id, v_contract.currency,
    'booking.settlement.partial_release', p_release_id::TEXT,
    'booking.release.customer:' || p_idempotency_key, p_correlation_id,
    'Release approved booking escrow', v_lines
  );

  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  IF v_supplier_delta > 0 THEN
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id,
      journal_entry_id
    ) VALUES (
      v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
      'supplier', 'final', v_supplier_delta, v_contract.currency,
      'supplier_release', p_release_id, v_customer_journal
    ) RETURNING id INTO v_supplier_allocation;
    v_provider_due_from := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.organization_id, p_actor_id,
      'interorganization_settlement_due_from', v_contract.currency
    );
    v_supplier_revenue := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.provider_organization_id, p_actor_id,
      'supplier_booking_service_revenue', v_contract.currency
    );
    v_provider_journal := post_booking_settlement_journal(
      v_contract.provider_organization_id, p_actor_id, v_contract.currency,
      'booking.settlement.provider_recognition', p_release_id::TEXT,
      'booking.release.provider:' || p_idempotency_key, p_correlation_id,
      'Recognize supplier booking proceeds',
      jsonb_build_array(
        jsonb_build_object(
          'account_id', v_provider_due_from, 'line_number', 1, 'side', 'debit',
          'amount_minor', v_supplier_delta,
          'memo', 'Settlement due from customer organization'
        ),
        jsonb_build_object(
          'account_id', v_supplier_revenue, 'line_number', 2, 'side', 'credit',
          'amount_minor', v_supplier_delta, 'memo', 'Booking service revenue'
        )
      )
    );
    INSERT INTO booking_settlement_posting_links(
      organization_id, settlement_contract_id, allocation_id, posting_role,
      journal_entry_id, correlation_id
    ) VALUES
      (
        v_contract.organization_id, v_contract.id, v_supplier_allocation,
        'customer_release', v_customer_journal, p_correlation_id
      ),
      (
        v_contract.provider_organization_id, v_contract.id, v_supplier_allocation,
        'provider_recognition', v_provider_journal, p_correlation_id
      );
  END IF;
  IF v_fee_delta > 0 THEN
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id,
      journal_entry_id
    ) VALUES (
      v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
      'platform_fee', 'final', v_fee_delta, v_contract.currency,
      'platform_fee', p_release_id, v_customer_journal
    ) RETURNING id INTO v_fee_allocation;
    v_platform_due_from := ensure_booking_settlement_account(
      v_fee.beneficiary_organization_id, v_contract.organization_id, p_actor_id,
      'interorganization_settlement_due_from', v_contract.currency
    );
    v_platform_revenue := ensure_booking_settlement_account(
      v_fee.beneficiary_organization_id, NULL, p_actor_id,
      'platform_booking_fee_revenue', v_contract.currency
    );
    v_platform_journal := post_booking_settlement_journal(
      v_fee.beneficiary_organization_id, p_actor_id, v_contract.currency,
      'booking.settlement.platform_recognition', p_release_id::TEXT,
      'booking.release.platform:' || p_idempotency_key, p_correlation_id,
      'Recognize platform booking fee',
      jsonb_build_array(
        jsonb_build_object(
          'account_id', v_platform_due_from, 'line_number', 1, 'side', 'debit',
          'amount_minor', v_fee_delta,
          'memo', 'Platform fee due from settlement organization'
        ),
        jsonb_build_object(
          'account_id', v_platform_revenue, 'line_number', 2, 'side', 'credit',
          'amount_minor', v_fee_delta, 'memo', 'Platform booking fee revenue'
        )
      )
    );
    INSERT INTO booking_settlement_posting_links(
      organization_id, settlement_contract_id, allocation_id, posting_role,
      journal_entry_id, correlation_id
    ) VALUES
      (
        v_contract.organization_id, v_contract.id, v_fee_allocation,
        'customer_release', v_customer_journal, p_correlation_id
      ),
      (
        v_fee.beneficiary_organization_id, v_contract.id, v_fee_allocation,
        'platform_recognition', v_platform_journal, p_correlation_id
      );
  END IF;

  INSERT INTO booking_settlement_releases(
    id, organization_id, provider_organization_id, settlement_contract_id,
    release_kind, source_id, release_base_minor, supplier_amount_minor,
    platform_fee_amount_minor, currency, customer_journal_entry_id,
    provider_journal_entry_id, platform_journal_entry_id, idempotency_key,
    request_hash, correlation_id
  ) VALUES (
    p_release_id, v_contract.organization_id, v_contract.provider_organization_id,
    v_contract.id, p_release_kind, p_source_id, p_release_base_minor,
    v_supplier_delta, v_fee_delta, v_contract.currency, v_customer_journal,
    v_provider_journal, v_platform_journal, p_idempotency_key, v_hash,
    p_correlation_id
  ) RETURNING * INTO v_existing;
  UPDATE booking_settlement_contracts SET
    supplier_amount_minor = COALESCE(supplier_amount_minor, 0) + v_supplier_delta,
    platform_fee_amount_minor = COALESCE(platform_fee_amount_minor, 0) + v_fee_delta,
    released_at = NOW(),
    customer_release_journal_entry_id = v_customer_journal,
    provider_recognition_journal_entry_id = v_provider_journal,
    platform_recognition_journal_entry_id = v_platform_journal,
    updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object(
    'release', to_jsonb(v_existing), 'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION transition_booking_dispute(
  p_dispute_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_target_state TEXT,
  p_reason TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_dispute booking_disputes;
  v_contract booking_settlement_contracts;
  v_existing booking_dispute_events;
  v_previous_dispute TEXT;
  v_previous_settlement TEXT;
  v_from_state TEXT;
  v_hash TEXT;
  v_authorized BOOLEAN;
  v_blocking_hold BOOLEAN;
BEGIN
  IF p_dispute_id IS NULL OR p_acting_organization_id IS NULL OR p_actor_id IS NULL
    OR p_correlation_id IS NULL
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000
    OR p_target_state NOT IN ('evidence_collection', 'under_review', 'withdrawn', 'closed')
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_TRANSITION_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_dispute_id, p_acting_organization_id, p_actor_id, p_target_state, btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_dispute_events
  WHERE dispute_id = p_dispute_id
    AND public_payload->>'idempotency_key' = p_idempotency_key
  ORDER BY occurred_at DESC LIMIT 1;
  IF FOUND THEN
    IF v_existing.public_payload->>'request_hash' <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'dispute_id', p_dispute_id, 'state', v_existing.to_state,
      'idempotency_replay', TRUE
    );
  END IF;

  SELECT * INTO v_dispute FROM booking_disputes
  WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_FOUND'; END IF;
  IF p_acting_organization_id NOT IN (
    v_dispute.organization_id, v_dispute.provider_organization_id
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  v_authorized := is_active_platform_administrator(p_actor_id)
    OR has_booking_permission(
      p_acting_organization_id, p_actor_id,
      CASE WHEN p_target_state = 'withdrawn'
        THEN 'booking.disputes.open' ELSE 'booking.disputes.resolve' END
    );
  IF NOT v_authorized THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF p_target_state = 'withdrawn'
    AND p_acting_organization_id <> v_dispute.organization_id
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF NOT (
    (v_dispute.state = 'opened' AND p_target_state IN (
      'evidence_collection', 'under_review', 'withdrawn'
    ))
    OR (v_dispute.state = 'evidence_collection'
      AND p_target_state IN ('under_review', 'withdrawn'))
    OR (v_dispute.state IN (
      'resolved_customer', 'resolved_supplier', 'resolved_split', 'withdrawn'
    ) AND p_target_state = 'closed')
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_TRANSITION_NOT_ALLOWED'; END IF;

  v_from_state := v_dispute.state;
  v_previous_dispute := current_setting('microfams.booking_dispute_engine', TRUE);
  v_previous_settlement := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  UPDATE booking_disputes SET
    state = p_target_state,
    updated_at = NOW(),
    resolved_at = CASE WHEN p_target_state = 'closed' THEN NOW() ELSE resolved_at END
  WHERE id = v_dispute.id RETURNING * INTO v_dispute;

  IF p_target_state = 'withdrawn' THEN
    UPDATE booking_settlement_allocations
    SET state = 'released', updated_at = NOW()
    WHERE settlement_contract_id = v_dispute.settlement_contract_id
      AND allocation_type = 'contested' AND source_type = 'booking_dispute'
      AND source_id = v_dispute.id AND state = 'reserved';
    UPDATE booking_settlement_holds
    SET state = 'released', released_at = NOW()
    WHERE settlement_contract_id = v_dispute.settlement_contract_id
      AND hold_type = 'dispute' AND source_type = 'booking_dispute'
      AND source_id = v_dispute.id::TEXT AND state = 'active';
    SELECT EXISTS (
      SELECT 1 FROM booking_settlement_holds
      WHERE settlement_contract_id = v_dispute.settlement_contract_id
        AND state = 'active'
    ) INTO v_blocking_hold;
    SELECT * INTO v_contract FROM booking_settlement_contracts
    WHERE id = v_dispute.settlement_contract_id FOR UPDATE;
    UPDATE booking_settlement_contracts SET
      state = CASE
        WHEN v_blocking_hold THEN 'manual_review'
        WHEN completed_at IS NULL THEN 'funded'
        WHEN NOW() < dispute_deadline_at THEN 'completed_pending_window'
        ELSE 'eligible'
      END,
      updated_at = NOW()
    WHERE id = v_contract.id;
  END IF;

  INSERT INTO booking_dispute_events(
    organization_id, provider_organization_id, dispute_id, event_type,
    actor_organization_id, actor_id, from_state, to_state,
    public_payload, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
    CASE p_target_state
      WHEN 'withdrawn' THEN 'withdrawn'
      WHEN 'closed' THEN 'closed'
      ELSE 'state_changed'
    END,
    p_acting_organization_id, p_actor_id,
    v_from_state,
    p_target_state,
    jsonb_build_object(
      'reason', btrim(p_reason), 'idempotency_key', p_idempotency_key,
      'request_hash', v_hash
    ),
    p_correlation_id
  );
  IF p_target_state IN ('withdrawn', 'closed') THEN
    INSERT INTO booking_dispute_notices(
      organization_id, provider_organization_id, dispute_id,
      recipient_organization_id, notice_type, public_payload,
      idempotency_key, correlation_id
    ) VALUES
      (
        v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
        v_dispute.organization_id, p_target_state,
        jsonb_build_object('state', p_target_state),
        'dispute-' || p_target_state || ':' || v_dispute.id::TEXT || ':customer',
        p_correlation_id
      ),
      (
        v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
        v_dispute.provider_organization_id, p_target_state,
        jsonb_build_object('state', p_target_state),
        'dispute-' || p_target_state || ':' || v_dispute.id::TEXT || ':provider',
        p_correlation_id
      );
  END IF;
  PERFORM set_config(
    'microfams.booking_dispute_engine', COALESCE(v_previous_dispute, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine', COALESCE(v_previous_settlement, ''), TRUE
  );
  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id, 'state', v_dispute.state,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION propose_booking_dispute_resolution(
  p_dispute_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_customer_refund_minor BIGINT,
  p_supplier_release_minor BIGINT,
  p_platform_fee_minor BIGINT,
  p_recoverable_amount_minor BIGINT,
  p_loss_amount_minor BIGINT,
  p_reason TEXT,
  p_evidence_ids UUID[],
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_dispute booking_disputes;
  v_contract booking_settlement_contracts;
  v_fee booking_fee_rules;
  v_existing booking_dispute_resolution_proposals;
  v_proposal booking_dispute_resolution_proposals;
  v_hash TEXT;
  v_previous TEXT;
  v_previous_settlement TEXT;
  v_prior_base BIGINT;
  v_prior_fee BIGINT;
  v_release_base BIGINT;
  v_expected_fee BIGINT;
  v_total BIGINT;
  v_evidence_count INTEGER;
BEGIN
  IF p_dispute_id IS NULL OR p_acting_organization_id IS NULL OR p_actor_id IS NULL
    OR p_correlation_id IS NULL
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 20 AND 2000
    OR COALESCE(p_customer_refund_minor, -1) < 0
    OR COALESCE(p_supplier_release_minor, -1) < 0
    OR COALESCE(p_platform_fee_minor, -1) < 0
    OR COALESCE(p_recoverable_amount_minor, -1) < 0
    OR COALESCE(p_loss_amount_minor, -1) < 0
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_INVALID'; END IF;
  v_total := p_customer_refund_minor + p_supplier_release_minor
    + p_platform_fee_minor + p_recoverable_amount_minor + p_loss_amount_minor;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_dispute_id, p_acting_organization_id, p_actor_id,
    p_customer_refund_minor, p_supplier_release_minor, p_platform_fee_minor,
    p_recoverable_amount_minor, p_loss_amount_minor, btrim(p_reason),
    array_to_string(COALESCE(p_evidence_ids, '{}'), ',')
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_dispute_resolution_proposals
  WHERE organization_id = p_acting_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'proposal_id', v_existing.id, 'state', v_existing.state,
      'accounting_preview', v_existing.accounting_preview,
      'idempotency_replay', TRUE
    );
  END IF;

  SELECT * INTO v_dispute FROM booking_disputes
  WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_FOUND'; END IF;
  IF v_dispute.state <> 'under_review'
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_STATE_INVALID'; END IF;
  IF p_acting_organization_id NOT IN (
    v_dispute.organization_id, v_dispute.provider_organization_id
  ) OR NOT (
    is_active_platform_administrator(p_actor_id)
    OR has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.disputes.resolve'
    )
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF v_total <> v_dispute.contested_amount_minor
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_NOT_CONSERVED'; END IF;
  IF EXISTS (
    SELECT 1 FROM booking_dispute_resolution_proposals
    WHERE dispute_id = v_dispute.id AND state = 'pending_approval'
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_ALREADY_PENDING'; END IF;

  SELECT count(DISTINCT evidence.id) INTO v_evidence_count
  FROM booking_dispute_evidence AS evidence
  WHERE evidence.dispute_id = v_dispute.id
    AND evidence.id = ANY(COALESCE(p_evidence_ids, '{}'))
    AND (
      evidence.evidence_type IN ('statement', 'message')
      OR evidence.malware_scan_status = 'clean'
    );
  IF v_evidence_count <> cardinality(COALESCE(p_evidence_ids, '{}'))
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_EVIDENCE_INVALID'; END IF;

  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE id = v_dispute.settlement_contract_id FOR UPDATE;
  IF v_contract.fee_rule_id IS NULL THEN
    SELECT * INTO v_fee FROM booking_fee_rules
    WHERE organization_id = v_contract.organization_id
      AND currency = v_contract.currency AND status = 'active'
      AND effective_from <= v_contract.funded_at
      AND (effective_until IS NULL OR effective_until > v_contract.funded_at)
    ORDER BY version DESC LIMIT 1;
    IF FOUND THEN
      v_previous_settlement := current_setting(
        'microfams.booking_settlement_engine', TRUE
      );
      PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
      UPDATE booking_settlement_contracts
      SET fee_rule_id = v_fee.id, updated_at = NOW()
      WHERE id = v_contract.id;
      PERFORM set_config(
        'microfams.booking_settlement_engine',
        COALESCE(v_previous_settlement, ''), TRUE
      );
      v_contract.fee_rule_id := v_fee.id;
    END IF;
  ELSE
    SELECT * INTO v_fee FROM booking_fee_rules WHERE id = v_contract.fee_rule_id;
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_FEE_RULE_UNAVAILABLE'; END IF;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_prior_base
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_prior_fee
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'platform_fee' AND state = 'final';
  v_release_base := p_supplier_release_minor + p_platform_fee_minor;
  v_expected_fee := CASE WHEN v_release_base = 0 THEN 0 ELSE least(
    greatest(calculate_booking_fee_minor(
      v_prior_base + v_release_base,
      v_fee.fixed_amount_minor, v_fee.basis_points,
      v_fee.minimum_amount_minor, v_fee.maximum_amount_minor
    ) - v_prior_fee, 0),
    v_release_base
  ) END;
  IF p_platform_fee_minor <> v_expected_fee
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_PLATFORM_FEE_MISMATCH'; END IF;

  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  INSERT INTO booking_dispute_resolution_proposals(
    organization_id, provider_organization_id, dispute_id, settlement_contract_id,
    customer_refund_minor, supplier_release_minor, platform_fee_minor,
    recoverable_amount_minor, loss_amount_minor, currency, reason, evidence_ids,
    accounting_preview, proposed_by_organization_id, proposed_by,
    idempotency_key, request_hash, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id,
    v_dispute.id, v_contract.id,
    p_customer_refund_minor, p_supplier_release_minor, p_platform_fee_minor,
    p_recoverable_amount_minor, p_loss_amount_minor, v_dispute.currency,
    btrim(p_reason), COALESCE(p_evidence_ids, '{}'),
    jsonb_build_object(
      'customer_refund_minor', p_customer_refund_minor,
      'supplier_release_minor', p_supplier_release_minor,
      'platform_fee_minor', p_platform_fee_minor,
      'recoverable_amount_minor', p_recoverable_amount_minor,
      'loss_amount_minor', p_loss_amount_minor,
      'contested_amount_minor', v_dispute.contested_amount_minor,
      'currency', v_dispute.currency,
      'prior_release_base_minor', v_prior_base,
      'prior_platform_fee_minor', v_prior_fee,
      'cumulative_fee_rule_id', v_contract.fee_rule_id,
      'balanced', TRUE
    ),
    p_acting_organization_id, p_actor_id, p_idempotency_key, v_hash, p_correlation_id
  ) RETURNING * INTO v_proposal;
  INSERT INTO booking_dispute_resolution_allocations(
    organization_id, provider_organization_id, dispute_id, proposal_id,
    allocation_type, amount_minor, currency
  )
  SELECT
    v_dispute.organization_id, v_dispute.provider_organization_id,
    v_dispute.id, v_proposal.id, allocation_type, amount_minor, v_dispute.currency
  FROM (VALUES
    ('customer_refund', p_customer_refund_minor),
    ('supplier_release', p_supplier_release_minor),
    ('platform_fee', p_platform_fee_minor),
    ('recoverable', p_recoverable_amount_minor),
    ('loss', p_loss_amount_minor)
  ) AS allocation(allocation_type, amount_minor)
  WHERE amount_minor > 0;
  UPDATE booking_disputes SET state = 'resolution_proposed', updated_at = NOW()
  WHERE id = v_dispute.id;
  INSERT INTO booking_dispute_events(
    organization_id, provider_organization_id, dispute_id, event_type,
    actor_organization_id, actor_id, from_state, to_state,
    public_payload, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
    'resolution_proposed', p_acting_organization_id, p_actor_id,
    'under_review', 'resolution_proposed',
    jsonb_build_object(
      'proposal_id', v_proposal.id,
      'accounting_preview', v_proposal.accounting_preview
    ),
    p_correlation_id
  );
  INSERT INTO booking_dispute_notices(
    organization_id, provider_organization_id, dispute_id,
    recipient_organization_id, notice_type, public_payload,
    idempotency_key, correlation_id
  ) VALUES
    (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
      v_dispute.organization_id, 'resolution_proposed',
      jsonb_build_object('proposal_id', v_proposal.id),
      'resolution-proposed:' || v_proposal.id::TEXT || ':customer', p_correlation_id
    ),
    (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
      v_dispute.provider_organization_id, 'resolution_proposed',
      jsonb_build_object('proposal_id', v_proposal.id),
      'resolution-proposed:' || v_proposal.id::TEXT || ':provider', p_correlation_id
    );
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object(
    'proposal_id', v_proposal.id, 'state', v_proposal.state,
    'accounting_preview', v_proposal.accounting_preview,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_dispute_resolution(
  p_proposal_id UUID,
  p_actor_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_proposal booking_dispute_resolution_proposals;
  v_dispute booking_disputes;
  v_contract booking_settlement_contracts;
  v_refund payment_refunds;
  v_release JSONB;
  v_release_id UUID;
  v_recovery_id UUID;
  v_loss_id UUID;
  v_hash TEXT;
  v_previous_dispute TEXT;
  v_previous_settlement TEXT;
  v_resolution_state TEXT;
  v_release_base BIGINT;
  v_refunded BIGINT;
  v_released BIGINT;
  v_contested BIGINT;
BEGIN
  IF p_proposal_id IS NULL OR p_actor_id IS NULL OR p_approve IS NULL
    OR p_correlation_id IS NULL
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_DECISION_INVALID'; END IF;
  SELECT * INTO v_proposal FROM booking_dispute_resolution_proposals
  WHERE id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_NOT_FOUND'; END IF;
  SELECT * INTO v_dispute FROM booking_disputes
  WHERE id = v_proposal.dispute_id FOR UPDATE;
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE id = v_proposal.settlement_contract_id FOR UPDATE;
  IF NOT is_active_platform_administrator(p_actor_id)
    OR EXISTS (
      SELECT 1 FROM organization_memberships
      WHERE user_id = p_actor_id AND status = 'active'
        AND organization_id IN (
          v_dispute.organization_id, v_dispute.provider_organization_id
        )
    )
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT'; END IF;
  IF v_proposal.proposed_by = p_actor_id
  THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_proposal_id, p_actor_id, p_approve, btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  IF v_proposal.state <> 'pending_approval' THEN
    IF v_proposal.decision_idempotency_key = p_idempotency_key
      AND v_proposal.decision_request_hash = v_hash
    THEN RETURN jsonb_build_object(
      'proposal_id', v_proposal.id, 'state', v_proposal.state,
      'dispute_state', v_dispute.state, 'idempotency_replay', TRUE
    ); END IF;
    RAISE EXCEPTION 'BOOKING_DISPUTE_DECISION_ALREADY_RECORDED';
  END IF;
  IF v_dispute.state <> 'resolution_proposed'
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_STATE_INVALID'; END IF;

  v_previous_dispute := current_setting('microfams.booking_dispute_engine', TRUE);
  v_previous_settlement := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);

  IF NOT p_approve THEN
    UPDATE booking_dispute_resolution_proposals SET
      state = 'rejected', decided_by = p_actor_id, decision_reason = btrim(p_reason),
      decision_idempotency_key = p_idempotency_key,
      decision_request_hash = v_hash, decided_at = NOW()
    WHERE id = v_proposal.id RETURNING * INTO v_proposal;
    UPDATE booking_dispute_resolution_allocations SET state = 'rejected'
    WHERE proposal_id = v_proposal.id;
    UPDATE booking_disputes SET state = 'under_review', updated_at = NOW()
    WHERE id = v_dispute.id RETURNING * INTO v_dispute;
    INSERT INTO booking_dispute_events(
      organization_id, provider_organization_id, dispute_id, event_type,
      actor_id, from_state, to_state, public_payload, correlation_id
    ) VALUES (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
      'state_changed', p_actor_id, 'resolution_proposed', 'under_review',
      jsonb_build_object(
        'proposal_id', v_proposal.id, 'decision', 'rejected',
        'reason', btrim(p_reason)
      ),
      p_correlation_id
    );
    INSERT INTO booking_dispute_notices(
      organization_id, provider_organization_id, dispute_id,
      recipient_organization_id, notice_type, public_payload,
      idempotency_key, correlation_id
    ) VALUES
      (
        v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
        v_dispute.organization_id, 'resolution_rejected',
        jsonb_build_object('proposal_id', v_proposal.id),
        'resolution-rejected:' || v_proposal.id::TEXT || ':customer', p_correlation_id
      ),
      (
        v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
        v_dispute.provider_organization_id, 'resolution_rejected',
        jsonb_build_object('proposal_id', v_proposal.id),
        'resolution-rejected:' || v_proposal.id::TEXT || ':provider', p_correlation_id
      );
    PERFORM set_config(
      'microfams.booking_dispute_engine', COALESCE(v_previous_dispute, ''), TRUE
    );
    PERFORM set_config(
      'microfams.booking_settlement_engine', COALESCE(v_previous_settlement, ''), TRUE
    );
    RETURN jsonb_build_object(
      'proposal_id', v_proposal.id, 'state', v_proposal.state,
      'dispute_state', v_dispute.state, 'idempotency_replay', FALSE
    );
  END IF;

  IF v_proposal.customer_refund_minor > 0 THEN
    v_refund := create_payment_refund(
      v_contract.payment_id,
      'DISPUTE-' || replace(v_proposal.id::TEXT, '-', ''),
      'dispute-refund:' || v_proposal.id::TEXT,
      v_proposal.customer_refund_minor,
      'booking_dispute_resolution',
      left(v_proposal.reason, 500),
      p_actor_id,
      v_proposal.id::TEXT
    );
  END IF;
  v_release_base := v_proposal.supplier_release_minor + v_proposal.platform_fee_minor;
  IF v_release_base > 0 THEN
    v_release_id := gen_random_uuid();
    v_release := apply_booking_release_allocation(
      v_contract.id, p_actor_id, v_release_id, 'dispute_resolution',
      v_proposal.id, v_release_base, v_proposal.platform_fee_minor,
      'dispute-release:' || v_proposal.id::TEXT, p_correlation_id
    );
  END IF;

  UPDATE booking_settlement_allocations
  SET state = 'released', updated_at = NOW()
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND source_type = 'booking_dispute'
    AND source_id = v_dispute.id AND state = 'reserved';
  IF v_proposal.recoverable_amount_minor > 0 THEN
    INSERT INTO booking_dispute_recovery_commands(
      organization_id, provider_organization_id, dispute_id, proposal_id,
      recovery_type, amount_minor, currency, reason, idempotency_key, correlation_id
    ) VALUES (
      v_dispute.organization_id, v_dispute.provider_organization_id,
      v_dispute.id, v_proposal.id, 'recoverable',
      v_proposal.recoverable_amount_minor, v_proposal.currency,
      v_proposal.reason, 'dispute-recovery:' || v_proposal.id::TEXT,
      p_correlation_id
    ) RETURNING id INTO v_recovery_id;
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id
    ) VALUES (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_contract.id,
      'contested', 'final', v_proposal.recoverable_amount_minor,
      v_proposal.currency, 'booking_dispute', v_recovery_id
    );
  END IF;
  IF v_proposal.loss_amount_minor > 0 THEN
    INSERT INTO booking_dispute_recovery_commands(
      organization_id, provider_organization_id, dispute_id, proposal_id,
      recovery_type, amount_minor, currency, reason, idempotency_key, correlation_id
    ) VALUES (
      v_dispute.organization_id, v_dispute.provider_organization_id,
      v_dispute.id, v_proposal.id, 'loss',
      v_proposal.loss_amount_minor, v_proposal.currency,
      v_proposal.reason, 'dispute-loss:' || v_proposal.id::TEXT,
      p_correlation_id
    ) RETURNING id INTO v_loss_id;
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id
    ) VALUES (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_contract.id,
      'contested', 'final', v_proposal.loss_amount_minor,
      v_proposal.currency, 'booking_dispute', v_loss_id
    );
  END IF;
  UPDATE booking_settlement_holds
  SET state = 'released', released_at = NOW()
  WHERE settlement_contract_id = v_contract.id
    AND hold_type = 'dispute' AND source_type = 'booking_dispute'
    AND source_id = v_dispute.id::TEXT AND state = 'active';

  v_resolution_state := CASE
    WHEN v_proposal.customer_refund_minor = v_dispute.contested_amount_minor
      THEN 'resolved_customer'
    WHEN v_release_base = v_dispute.contested_amount_minor
      THEN 'resolved_supplier'
    ELSE 'resolved_split'
  END;
  UPDATE booking_dispute_resolution_proposals SET
    state = 'approved', decided_by = p_actor_id, decision_reason = btrim(p_reason),
    decision_idempotency_key = p_idempotency_key,
    decision_request_hash = v_hash, decided_at = NOW(),
    refund_id = v_refund.id, release_id = v_release_id
  WHERE id = v_proposal.id RETURNING * INTO v_proposal;
  UPDATE booking_dispute_resolution_allocations SET state = 'approved'
  WHERE proposal_id = v_proposal.id;
  UPDATE booking_disputes SET
    state = v_resolution_state, updated_at = NOW(), resolved_at = NOW()
  WHERE id = v_dispute.id RETURNING * INTO v_dispute;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_released
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  UPDATE booking_settlement_contracts SET
    state = CASE
      WHEN v_proposal.recoverable_amount_minor + v_proposal.loss_amount_minor > 0
        THEN 'manual_review'
      WHEN v_refunded = 0 AND v_released = gross_amount_minor THEN 'settled'
      ELSE 'partially_settled'
    END,
    updated_at = NOW()
  WHERE id = v_contract.id;

  INSERT INTO booking_dispute_events(
    organization_id, provider_organization_id, dispute_id, event_type,
    actor_id, from_state, to_state, public_payload, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
    'resolved', p_actor_id, 'resolution_proposed', v_resolution_state,
    jsonb_build_object(
      'proposal_id', v_proposal.id,
      'decision', 'approved',
      'customer_refund_minor', v_proposal.customer_refund_minor,
      'supplier_release_minor', v_proposal.supplier_release_minor,
      'platform_fee_minor', v_proposal.platform_fee_minor,
      'recoverable_amount_minor', v_proposal.recoverable_amount_minor,
      'loss_amount_minor', v_proposal.loss_amount_minor,
      'refund_id', v_refund.id, 'release_id', v_release_id
    ),
    p_correlation_id
  );
  INSERT INTO booking_dispute_notices(
    organization_id, provider_organization_id, dispute_id,
    recipient_organization_id, notice_type, public_payload,
    idempotency_key, correlation_id
  ) VALUES
    (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
      v_dispute.organization_id, 'resolution_approved',
      jsonb_build_object(
        'proposal_id', v_proposal.id, 'state', v_resolution_state
      ),
      'resolution-approved:' || v_proposal.id::TEXT || ':customer', p_correlation_id
    ),
    (
      v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
      v_dispute.provider_organization_id, 'resolution_approved',
      jsonb_build_object(
        'proposal_id', v_proposal.id, 'state', v_resolution_state
      ),
      'resolution-approved:' || v_proposal.id::TEXT || ':provider', p_correlation_id
    );
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES
    (
      v_dispute.organization_id, p_actor_id, 'booking.dispute.resolved',
      'booking_dispute', v_dispute.id::TEXT,
      jsonb_build_object(
        'proposal_id', v_proposal.id, 'state', v_resolution_state,
        'correlation_id', p_correlation_id
      )
    ),
    (
      v_dispute.provider_organization_id, p_actor_id, 'booking.dispute.resolved',
      'booking_dispute', v_dispute.id::TEXT,
      jsonb_build_object(
        'proposal_id', v_proposal.id, 'state', v_resolution_state,
        'correlation_id', p_correlation_id
      )
    );
  PERFORM set_config(
    'microfams.booking_dispute_engine', COALESCE(v_previous_dispute, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine', COALESCE(v_previous_settlement, ''), TRUE
  );
  RETURN jsonb_build_object(
    'proposal_id', v_proposal.id, 'state', v_proposal.state,
    'dispute_state', v_dispute.state, 'refund_id', v_refund.id,
    'release_id', v_release_id, 'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION release_booking_settlement(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_booking bookings;
  v_payment payments;
  v_refunded BIGINT;
  v_contested BIGINT;
  v_released BIGINT;
  v_reversed BIGINT;
  v_available BIGINT;
  v_release_id UUID := gen_random_uuid();
  v_result JSONB;
  v_release booking_settlement_releases;
  v_previous TEXT;
BEGIN
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REQUEST_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'booking-release:' || p_booking_id::TEXT, 0
  ));
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND'; END IF;
  SELECT * INTO v_release FROM booking_settlement_releases
  WHERE organization_id = v_contract.organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'settlement', to_jsonb(v_contract), 'release', to_jsonb(v_release),
      'idempotency_replay', TRUE
    );
  END IF;
  IF p_acting_organization_id <> v_contract.organization_id
    OR NOT has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.settlements.release'
    )
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_booking FROM bookings WHERE id = v_contract.booking_id FOR UPDATE;
  SELECT * INTO v_payment FROM payments WHERE id = v_contract.payment_id FOR UPDATE;
  IF v_booking.status <> 'completed' OR v_contract.completed_at IS NULL
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_COMPLETED'; END IF;
  IF NOW() < v_contract.dispute_deadline_at
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_DISPUTE_WINDOW_OPEN'; END IF;
  IF v_payment.state NOT IN ('succeeded', 'partially_refunded')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_PAYMENT_NOT_ELIGIBLE'; END IF;
  IF EXISTS (
    SELECT 1 FROM organizations
    WHERE id IN (v_contract.organization_id, v_contract.provider_organization_id)
      AND status <> 'active'
  ) THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ORGANIZATION_INACTIVE'; END IF;
  IF EXISTS (
    SELECT 1 FROM organization_suspensions
    WHERE organization_id IN (
      v_contract.organization_id, v_contract.provider_organization_id
    ) AND status = 'active'
  ) THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ORGANIZATION_SUSPENDED'; END IF;
  IF EXISTS (
    SELECT 1 FROM data_legal_holds
    WHERE status = 'active' AND subject_type = 'organization'
      AND subject_id IN (
        v_contract.organization_id::TEXT,
        v_contract.provider_organization_id::TEXT
      )
  ) THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_LEGAL_HOLD'; END IF;
  IF EXISTS (
    SELECT 1 FROM financial_risk_controls
    WHERE organization_id IN (
      v_contract.organization_id, v_contract.provider_organization_id
    )
      AND released_at IS NULL AND effective_from <= NOW()
      AND (effective_until IS NULL OR effective_until > NOW())
      AND product IN ('*', 'booking', 'booking_settlement')
      AND subject_type = 'organization' AND subject_id = organization_id::TEXT
  ) THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_RISK_HOLD'; END IF;
  IF EXISTS (
    SELECT 1 FROM booking_settlement_holds
    WHERE settlement_contract_id = v_contract.id AND state = 'active'
      AND (
        hold_type NOT IN ('dispute', 'refund')
        OR amount_minor IS NULL
        OR (hold_type = 'refund' AND reason_code <> 'refund_pending')
      )
  ) THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_HOLD_ACTIVE'; END IF;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_released
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_reversed
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'reversal' AND state = 'final';
  IF v_reversed > 0 THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REVERSED'; END IF;
  v_available := v_contract.gross_amount_minor
    - v_refunded - v_contested - v_released;
  IF v_available <= 0
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NO_RELEASABLE_AMOUNT'; END IF;

  v_result := apply_booking_release_allocation(
    v_contract.id, p_actor_id, v_release_id, 'ordinary', p_booking_id,
    v_available, NULL, p_idempotency_key, p_correlation_id
  );
  SELECT * INTO v_release FROM booking_settlement_releases WHERE id = v_release_id;
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  UPDATE booking_settlement_contracts SET
    state = CASE
      WHEN v_refunded + v_contested = 0
        AND v_released + v_available = gross_amount_minor THEN 'settled'
      ELSE 'partially_settled'
    END,
    eligible_at = NOW(),
    release_idempotency_key = p_idempotency_key,
    release_request_hash = v_release.request_hash,
    release_correlation_id = p_correlation_id,
    eligibility_snapshot = COALESCE(eligibility_snapshot, '{}'::JSONB)
      || jsonb_build_object(
        'evaluated_at', NOW(),
        'gross_amount_minor', gross_amount_minor,
        'reserved_or_refunded_amount_minor', v_refunded,
        'contested_amount_minor', v_contested,
        'previously_released_amount_minor', v_released,
        'release_base_minor', v_available,
        'cumulative_fee_mode', TRUE,
        'release_correlation_id', p_correlation_id
      ),
    updated_at = NOW()
  WHERE id = v_contract.id RETURNING * INTO v_contract;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES
    (
      v_contract.organization_id, p_actor_id, 'booking.settlement.released',
      'booking_settlement', v_contract.id::TEXT,
      jsonb_build_object(
        'booking_id', v_contract.booking_id,
        'release_id', v_release.id,
        'release_base_minor', v_release.release_base_minor,
        'supplier_amount_minor', v_release.supplier_amount_minor,
        'platform_fee_amount_minor', v_release.platform_fee_amount_minor,
        'correlation_id', p_correlation_id
      )
    ),
    (
      v_contract.provider_organization_id, p_actor_id,
      'booking.settlement.recognized', 'booking_settlement', v_contract.id::TEXT,
      jsonb_build_object(
        'booking_id', v_contract.booking_id,
        'release_id', v_release.id,
        'supplier_amount_minor', v_release.supplier_amount_minor,
        'correlation_id', p_correlation_id
      )
    );
  RETURN jsonb_build_object(
    'settlement', to_jsonb(v_contract), 'release', to_jsonb(v_release),
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_settlement_summary(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_refunded BIGINT;
  v_contested BIGINT;
  v_supplier BIGINT;
  v_fee BIGINT;
BEGIN
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND'; END IF;
  IF p_acting_organization_id NOT IN (
      v_contract.organization_id, v_contract.provider_organization_id
    )
    OR NOT has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.settlements.read'
    )
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_AUTHORIZED'; END IF;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_supplier
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'supplier' AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_fee
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'platform_fee' AND state = 'final';
  RETURN jsonb_build_object(
    'id', v_contract.id, 'booking_id', v_contract.booking_id,
    'customer_organization_id', v_contract.organization_id,
    'provider_organization_id', v_contract.provider_organization_id,
    'currency', v_contract.currency, 'state', v_contract.state,
    'gross_amount_minor', v_contract.gross_amount_minor,
    'reserved_or_refunded_amount_minor', v_refunded,
    'contested_amount_minor', v_contested,
    'supplier_amount_minor', v_supplier,
    'platform_fee_amount_minor', v_fee,
    'unallocated_escrow_minor',
      v_contract.gross_amount_minor - v_refunded - v_contested - v_supplier - v_fee,
    'completed_at', v_contract.completed_at,
    'dispute_deadline_at', v_contract.dispute_deadline_at,
    'timezone', v_contract.settlement_timezone,
    'released_at', v_contract.released_at,
    'eligibility_snapshot', v_contract.eligibility_snapshot,
    'releases', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', release.id, 'release_kind', release.release_kind,
        'release_base_minor', release.release_base_minor,
        'supplier_amount_minor', release.supplier_amount_minor,
        'platform_fee_amount_minor', release.platform_fee_amount_minor,
        'currency', release.currency, 'correlation_id', release.correlation_id,
        'created_at', release.created_at
      ) ORDER BY release.created_at, release.id)
      FROM booking_settlement_releases AS release
      WHERE release.settlement_contract_id = v_contract.id
    ), '[]'::JSONB)
  );
END;
$$;

CREATE OR REPLACE FUNCTION propose_booking_dispute_response_rule(
  p_organization_id UUID,
  p_actor_id UUID,
  p_version INTEGER,
  p_response_period_days INTEGER,
  p_effective_from TIMESTAMPTZ,
  p_change_reason TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_existing booking_dispute_response_rules;
  v_rule booking_dispute_response_rules;
  v_hash TEXT;
  v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_actor_id IS NULL
    OR COALESCE(p_version, 0) <= 0
    OR p_response_period_days NOT BETWEEN 1 AND 14
    OR p_effective_from IS NULL
    OR length(btrim(COALESCE(p_change_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'booking.disputes.rules.propose'
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id, p_actor_id, p_version, p_response_period_days,
    p_effective_from, btrim(p_change_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_dispute_response_rules
  WHERE organization_id = p_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'rule_id', v_existing.id, 'state', v_existing.status,
      'idempotency_replay', TRUE
    );
  END IF;
  IF EXISTS (
    SELECT 1 FROM booking_dispute_response_rules
    WHERE organization_id = p_organization_id AND version = p_version
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_VERSION_CONFLICT'; END IF;
  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  INSERT INTO booking_dispute_response_rules(
    organization_id, version, response_period_days, effective_from,
    change_reason, created_by, idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_version, p_response_period_days, p_effective_from,
    btrim(p_change_reason), p_actor_id, p_idempotency_key, v_hash
  ) RETURNING * INTO v_rule;
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object(
    'rule_id', v_rule.id, 'state', v_rule.status, 'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_dispute_response_rule(
  p_rule_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_rule booking_dispute_response_rules;
  v_hash TEXT;
  v_previous TEXT;
BEGIN
  IF p_rule_id IS NULL OR p_organization_id IS NULL OR p_actor_id IS NULL
    OR p_approve IS NULL
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_DECISION_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'booking.disputes.rules.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_rule FROM booking_dispute_response_rules
  WHERE id = p_rule_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_NOT_FOUND'; END IF;
  IF v_rule.created_by = p_actor_id THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_rule_id, p_organization_id, p_actor_id, p_approve, btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  IF v_rule.status <> 'pending_approval' THEN
    IF v_rule.decision_idempotency_key = p_idempotency_key
      AND v_rule.decision_request_hash = v_hash
    THEN RETURN jsonb_build_object(
      'rule_id', v_rule.id, 'state', v_rule.status, 'idempotency_replay', TRUE
    ); END IF;
    RAISE EXCEPTION 'BOOKING_DISPUTE_RESPONSE_RULE_DECIDED';
  END IF;
  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  IF p_approve THEN
    UPDATE booking_dispute_response_rules
    SET effective_until = v_rule.effective_from
    WHERE organization_id = v_rule.organization_id AND status = 'active'
      AND effective_from < v_rule.effective_from
      AND (effective_until IS NULL OR effective_until > v_rule.effective_from);
  END IF;
  UPDATE booking_dispute_response_rules SET
    status = CASE WHEN p_approve THEN 'active' ELSE 'rejected' END,
    approved_by = p_actor_id, approved_at = NOW(),
    decision_idempotency_key = p_idempotency_key,
    decision_request_hash = v_hash
  WHERE id = v_rule.id RETURNING * INTO v_rule;
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_rule.organization_id, p_actor_id,
    CASE WHEN p_approve
      THEN 'booking.dispute_response_rule.approved'
      ELSE 'booking.dispute_response_rule.rejected' END,
    'booking_dispute_response_rule', v_rule.id::TEXT,
    jsonb_build_object(
      'version', v_rule.version,
      'response_period_days', v_rule.response_period_days,
      'reason', btrim(p_reason)
    )
  );
  RETURN jsonb_build_object(
    'rule_id', v_rule.id, 'state', v_rule.status, 'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_dispute_resolution_case(
  p_dispute_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dispute booking_disputes;
BEGIN
  SELECT * INTO v_dispute FROM booking_disputes WHERE id = p_dispute_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_FOUND'; END IF;
  IF p_acting_organization_id NOT IN (
      v_dispute.organization_id, v_dispute.provider_organization_id
    ) OR NOT (
      is_active_platform_administrator(p_actor_id)
      OR has_booking_permission(
        p_acting_organization_id, p_actor_id, 'booking.disputes.read'
      )
    )
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id,
    'booking_id', v_dispute.booking_id,
    'state', v_dispute.state,
    'contested_amount_minor', v_dispute.contested_amount_minor,
    'currency', v_dispute.currency,
    'response_deadline_at', v_dispute.response_deadline_at,
    'proposals', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', proposal.id,
        'customer_refund_minor', proposal.customer_refund_minor,
        'supplier_release_minor', proposal.supplier_release_minor,
        'platform_fee_minor', proposal.platform_fee_minor,
        'recoverable_amount_minor', proposal.recoverable_amount_minor,
        'loss_amount_minor', proposal.loss_amount_minor,
        'currency', proposal.currency,
        'reason', proposal.reason,
        'evidence_ids', proposal.evidence_ids,
        'accounting_preview', proposal.accounting_preview,
        'state', proposal.state,
        'proposed_by_organization_id', proposal.proposed_by_organization_id,
        'decision_reason', proposal.decision_reason,
        'created_at', proposal.created_at,
        'decided_at', proposal.decided_at
      ) ORDER BY proposal.created_at, proposal.id)
      FROM booking_dispute_resolution_proposals AS proposal
      WHERE proposal.dispute_id = v_dispute.id
    ), '[]'::JSONB),
    'recovery_commands', CASE WHEN is_active_platform_administrator(p_actor_id)
      THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', recovery.id, 'recovery_type', recovery.recovery_type,
          'amount_minor', recovery.amount_minor, 'currency', recovery.currency,
          'state', recovery.state, 'created_at', recovery.created_at
        ) ORDER BY recovery.created_at, recovery.id)
        FROM booking_dispute_recovery_commands AS recovery
        WHERE recovery.dispute_id = v_dispute.id
      ), '[]'::JSONB)
      ELSE '[]'::JSONB END,
    'notices', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', notice.id, 'notice_type', notice.notice_type,
        'payload', notice.public_payload, 'state', notice.state,
        'created_at', notice.created_at, 'delivered_at', notice.delivered_at
      ) ORDER BY notice.created_at, notice.id)
      FROM booking_dispute_notices AS notice
      WHERE notice.dispute_id = v_dispute.id
        AND notice.recipient_organization_id = p_acting_organization_id
    ), '[]'::JSONB)
  );
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'booking.disputes.resolve',
    'booking.disputes.rules.propose',
    'booking.disputes.rules.approve'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_dispute_response_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_resolution_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_resolution_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_recovery_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_settlement_releases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_dispute_response_rules,
  booking_dispute_resolution_proposals,
  booking_dispute_resolution_allocations,
  booking_dispute_recovery_commands,
  booking_dispute_notices,
  booking_settlement_releases FROM anon, authenticated;
GRANT SELECT ON booking_dispute_response_rules,
  booking_dispute_resolution_proposals,
  booking_dispute_resolution_allocations,
  booking_dispute_recovery_commands,
  booking_dispute_notices,
  booking_settlement_releases TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_dispute_response_rules,
  booking_dispute_resolution_proposals,
  booking_dispute_resolution_allocations,
  booking_dispute_recovery_commands,
  booking_dispute_notices,
  booking_settlement_releases FROM service_role;

REVOKE ALL ON FUNCTION protect_booking_dispute_resolution_records()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION protect_booking_dispute_resolution_history()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION protect_booking_settlement_release_records()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION provision_default_booking_dispute_response_rule()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION snapshot_booking_dispute_response_rule()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION queue_booking_dispute_opened_notices()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION reserve_booking_refund_allocation()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION release_failed_booking_refund_reservation()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION apply_booking_release_allocation(
  UUID, UUID, UUID, TEXT, UUID, BIGINT, BIGINT, TEXT, UUID
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION transition_booking_dispute(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION transition_booking_dispute(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, UUID
) TO service_role;
REVOKE ALL ON FUNCTION propose_booking_dispute_resolution(
  UUID, UUID, UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
  TEXT, UUID[], TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_booking_dispute_resolution(
  UUID, UUID, UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
  TEXT, UUID[], TEXT, UUID
) TO service_role;
REVOKE ALL ON FUNCTION decide_booking_dispute_resolution(
  UUID, UUID, BOOLEAN, TEXT, TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION decide_booking_dispute_resolution(
  UUID, UUID, BOOLEAN, TEXT, TEXT, UUID
) TO service_role;
REVOKE ALL ON FUNCTION propose_booking_dispute_response_rule(
  UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_booking_dispute_response_rule(
  UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT
) TO service_role;
REVOKE ALL ON FUNCTION decide_booking_dispute_response_rule(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION decide_booking_dispute_response_rule(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) TO service_role;
REVOKE ALL ON FUNCTION read_booking_dispute_resolution_case(UUID, UUID, UUID)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_booking_dispute_resolution_case(UUID, UUID, UUID)
  TO service_role;
