-- BS-03/BS-04: effective-dated eligibility, fee rules, and atomic accounting release.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS booking_settlement_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  version INTEGER NOT NULL CHECK (version > 0),
  dispute_window_hours INTEGER NOT NULL CHECK (dispute_window_hours BETWEEN 0 AND 336),
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
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, version),
  UNIQUE (organization_id, idempotency_key),
  CHECK (effective_until IS NULL OR effective_until > effective_from),
  CHECK (approved_by IS NULL OR created_by IS NULL OR approved_by <> created_by)
);
CREATE INDEX IF NOT EXISTS idx_booking_settlement_rule_lookup
  ON booking_settlement_rules(organization_id, status, effective_from DESC);

CREATE TABLE IF NOT EXISTS booking_fee_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  beneficiary_organization_id UUID REFERENCES organizations(id),
  version INTEGER NOT NULL CHECK (version > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  payer TEXT NOT NULL DEFAULT 'supplier' CHECK (payer IN ('customer', 'supplier')),
  fixed_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (fixed_amount_minor >= 0),
  basis_points INTEGER NOT NULL DEFAULT 0 CHECK (basis_points BETWEEN 0 AND 10000),
  minimum_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (minimum_amount_minor >= 0),
  maximum_amount_minor BIGINT CHECK (maximum_amount_minor IS NULL OR maximum_amount_minor >= 0),
  tax_withholding_metadata JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(tax_withholding_metadata) = 'object'),
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
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, currency, version),
  UNIQUE (organization_id, idempotency_key),
  CHECK (effective_until IS NULL OR effective_until > effective_from),
  CHECK (maximum_amount_minor IS NULL OR maximum_amount_minor >= minimum_amount_minor),
  CHECK (
    (fixed_amount_minor = 0 AND basis_points = 0 AND minimum_amount_minor = 0
      AND COALESCE(maximum_amount_minor, 0) = 0)
    OR beneficiary_organization_id IS NOT NULL
  ),
  CHECK (approved_by IS NULL OR created_by IS NULL OR approved_by <> created_by)
);
CREATE INDEX IF NOT EXISTS idx_booking_fee_rule_lookup
  ON booking_fee_rules(organization_id, currency, status, effective_from DESC);

CREATE TABLE IF NOT EXISTS booking_settlement_holds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  hold_type TEXT NOT NULL CHECK (hold_type IN (
    'dispute', 'refund', 'risk', 'legal', 'reconciliation', 'chargeback', 'manual_review'
  )),
  amount_minor BIGINT CHECK (amount_minor IS NULL OR amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  source_type TEXT NOT NULL CHECK (length(source_type) BETWEEN 2 AND 80),
  source_id TEXT NOT NULL CHECK (length(source_id) BETWEEN 1 AND 160),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'released')),
  placed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  released_at TIMESTAMPTZ,
  UNIQUE (settlement_contract_id, hold_type, source_type, source_id),
  CHECK ((state = 'released') = (released_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_booking_settlement_active_holds
  ON booking_settlement_holds(settlement_contract_id, hold_type) WHERE state = 'active';

CREATE TABLE IF NOT EXISTS booking_settlement_posting_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  allocation_id UUID NOT NULL REFERENCES booking_settlement_allocations(id),
  posting_role TEXT NOT NULL CHECK (posting_role IN (
    'customer_release', 'provider_recognition', 'platform_recognition'
  )),
  journal_entry_id UUID NOT NULL REFERENCES journal_entries(id),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (allocation_id, posting_role)
);

ALTER TABLE booking_settlement_contracts
  ADD COLUMN IF NOT EXISTS completion_transition_id UUID UNIQUE REFERENCES booking_state_transitions(id),
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS dispute_deadline_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS settlement_timezone TEXT,
  ADD COLUMN IF NOT EXISTS settlement_rule_id UUID REFERENCES booking_settlement_rules(id),
  ADD COLUMN IF NOT EXISTS fee_rule_id UUID REFERENCES booking_fee_rules(id),
  ADD COLUMN IF NOT EXISTS eligibility_snapshot JSONB,
  ADD COLUMN IF NOT EXISTS eligible_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS supplier_amount_minor BIGINT CHECK (supplier_amount_minor IS NULL OR supplier_amount_minor >= 0),
  ADD COLUMN IF NOT EXISTS platform_fee_amount_minor BIGINT CHECK (platform_fee_amount_minor IS NULL OR platform_fee_amount_minor >= 0),
  ADD COLUMN IF NOT EXISTS release_idempotency_key TEXT,
  ADD COLUMN IF NOT EXISTS release_request_hash VARCHAR(64),
  ADD COLUMN IF NOT EXISTS release_correlation_id UUID,
  ADD COLUMN IF NOT EXISTS customer_release_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  ADD COLUMN IF NOT EXISTS provider_recognition_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  ADD COLUMN IF NOT EXISTS platform_recognition_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id);

ALTER TABLE booking_settlement_contracts
  ADD CONSTRAINT booking_settlement_completion_shape CHECK (
    (completed_at IS NULL AND dispute_deadline_at IS NULL AND settlement_timezone IS NULL
      AND settlement_rule_id IS NULL)
    OR
    (completed_at IS NOT NULL AND dispute_deadline_at IS NOT NULL
      AND dispute_deadline_at >= completed_at AND settlement_timezone IS NOT NULL
      AND settlement_rule_id IS NOT NULL)
  ),
  ADD CONSTRAINT booking_settlement_release_idempotency_shape CHECK (
    (release_idempotency_key IS NULL AND release_request_hash IS NULL AND release_correlation_id IS NULL)
    OR
    (length(release_idempotency_key) BETWEEN 8 AND 160
      AND release_request_hash ~ '^[a-f0-9]{64}$' AND release_correlation_id IS NOT NULL)
  );
CREATE UNIQUE INDEX IF NOT EXISTS uq_booking_settlement_release_key
  ON booking_settlement_contracts(organization_id, release_idempotency_key)
  WHERE release_idempotency_key IS NOT NULL;

ALTER TABLE financial_approval_requests
  ADD COLUMN IF NOT EXISTS decision_idempotency_key TEXT,
  ADD COLUMN IF NOT EXISTS decision_request_hash VARCHAR(64);
ALTER TABLE financial_approval_requests
  ADD CONSTRAINT booking_rule_decision_idempotency_shape CHECK (
    (decision_idempotency_key IS NULL AND decision_request_hash IS NULL)
    OR
    (length(decision_idempotency_key) BETWEEN 8 AND 160
      AND decision_request_hash ~ '^[a-f0-9]{64}$')
  );
CREATE UNIQUE INDEX IF NOT EXISTS uq_booking_rule_decision_key
  ON financial_approval_requests(organization_id, decision_idempotency_key)
  WHERE decision_idempotency_key IS NOT NULL
    AND resource_type IN ('booking_settlement_rule', 'booking_fee_rule');

CREATE OR REPLACE FUNCTION protect_booking_rule_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_rule_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking financial rules can only be changed by the rule engine';
END;
$$;
CREATE OR REPLACE FUNCTION protect_booking_settlement_extension_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_settlement_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking settlement extension records can only be changed by the settlement engine';
END;
$$;
CREATE TRIGGER booking_settlement_rules_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_rules
  FOR EACH ROW EXECUTE FUNCTION protect_booking_rule_records();
CREATE TRIGGER booking_fee_rules_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_fee_rules
  FOR EACH ROW EXECUTE FUNCTION protect_booking_rule_records();
CREATE TRIGGER booking_settlement_holds_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_holds
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_extension_records();
CREATE TRIGGER booking_settlement_posting_links_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_settlement_posting_links
  FOR EACH ROW EXECUTE FUNCTION protect_booking_settlement_extension_records();

CREATE OR REPLACE FUNCTION calculate_booking_fee_minor(
  p_release_base_minor BIGINT, p_fixed_amount_minor BIGINT, p_basis_points INTEGER,
  p_minimum_amount_minor BIGINT, p_maximum_amount_minor BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE v_fee NUMERIC;
BEGIN
  IF p_release_base_minor IS NULL OR p_release_base_minor < 0
    OR p_fixed_amount_minor IS NULL OR p_fixed_amount_minor < 0
    OR p_basis_points IS NULL OR p_basis_points NOT BETWEEN 0 AND 10000
    OR p_minimum_amount_minor IS NULL OR p_minimum_amount_minor < 0
    OR (p_maximum_amount_minor IS NOT NULL AND p_maximum_amount_minor < p_minimum_amount_minor)
  THEN RAISE EXCEPTION 'BOOKING_FEE_RULE_INVALID'; END IF;
  IF p_release_base_minor = 0 THEN RETURN 0; END IF;
  v_fee := p_fixed_amount_minor
    + floor(((p_release_base_minor::NUMERIC * p_basis_points::NUMERIC) + 5000) / 10000);
  v_fee := greatest(v_fee, p_minimum_amount_minor);
  IF p_maximum_amount_minor IS NOT NULL THEN v_fee := least(v_fee, p_maximum_amount_minor); END IF;
  v_fee := least(v_fee, p_release_base_minor);
  IF v_fee > 9223372036854775807 THEN RAISE EXCEPTION 'BOOKING_FEE_OVERFLOW'; END IF;
  RETURN v_fee::BIGINT;
END;
$$;

CREATE OR REPLACE FUNCTION has_booking_permission(
  p_organization_id UUID, p_actor_id UUID, p_permission TEXT
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id AND status = 'active'
      AND (role = 'owner' OR p_permission = ANY(permissions) OR 'booking.*' = ANY(permissions))
  );
$$;

CREATE OR REPLACE FUNCTION provision_default_booking_financial_rules() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_rule_engine', TRUE);
  PERFORM set_config('microfams.booking_rule_engine', 'on', TRUE);
  INSERT INTO booking_settlement_rules(
    organization_id, version, dispute_window_hours, status, effective_from,
    change_reason, idempotency_key, request_hash
  ) VALUES (
    NEW.id, 1, 48, 'active', '-infinity',
    'Approved BS-03 default dispute window.', 'default-bs03-rule',
    encode(digest(convert_to(NEW.id::TEXT || '|BS03|1|48', 'UTF8'), 'sha256'), 'hex')
  ) ON CONFLICT (organization_id, version) DO NOTHING;
  INSERT INTO booking_fee_rules(
    organization_id, version, currency, payer, fixed_amount_minor, basis_points,
    minimum_amount_minor, maximum_amount_minor, status, effective_from,
    change_reason, idempotency_key, request_hash
  ) VALUES (
    NEW.id, 1, NEW.default_currency, 'supplier', 0, 0, 0, 0, 'active', '-infinity',
    'Approved BS-04 zero-fee default.', 'default-bs04-rule',
    encode(digest(convert_to(NEW.id::TEXT || '|BS04|1|0', 'UTF8'), 'sha256'), 'hex')
  ) ON CONFLICT (organization_id, currency, version) DO NOTHING;
  PERFORM set_config('microfams.booking_rule_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  PERFORM set_config('microfams.booking_rule_engine', 'on', TRUE);
  INSERT INTO booking_settlement_rules(
    organization_id, version, dispute_window_hours, status, effective_from,
    change_reason, idempotency_key, request_hash
  )
  SELECT
    organization.id, 1, 48, 'active', '-infinity',
    'Approved BS-03 default dispute window.', 'default-bs03-rule',
    encode(digest(convert_to(organization.id::TEXT || '|BS03|1|48', 'UTF8'), 'sha256'), 'hex')
  FROM organizations AS organization
  ON CONFLICT (organization_id, version) DO NOTHING;

  INSERT INTO booking_fee_rules(
    organization_id, version, currency, payer, fixed_amount_minor, basis_points,
    minimum_amount_minor, maximum_amount_minor, status, effective_from,
    change_reason, idempotency_key, request_hash
  )
  SELECT
    organization.id, 1, organization.default_currency, 'supplier', 0, 0, 0, 0,
    'active', '-infinity', 'Approved BS-04 zero-fee default.', 'default-bs04-rule',
    encode(digest(convert_to(organization.id::TEXT || '|BS04|1|0', 'UTF8'), 'sha256'), 'hex')
  FROM organizations AS organization
  ON CONFLICT (organization_id, currency, version) DO NOTHING;
END;
$$;

DROP TRIGGER IF EXISTS provision_default_booking_financial_rules_trigger ON organizations;
CREATE TRIGGER provision_default_booking_financial_rules_trigger
  AFTER INSERT ON organizations FOR EACH ROW
  EXECUTE FUNCTION provision_default_booking_financial_rules();

CREATE OR REPLACE FUNCTION propose_booking_settlement_rule(
  p_organization_id UUID, p_actor_id UUID, p_version INTEGER,
  p_dispute_window_hours INTEGER, p_effective_from TIMESTAMPTZ,
  p_change_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_rule booking_settlement_rules; v_hash TEXT; v_approval UUID; v_previous TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization_id, p_actor_id, 'financial.rules.propose')
  THEN RAISE EXCEPTION 'BOOKING_RULE_NOT_AUTHORIZED'; END IF;
  IF p_version IS NULL OR p_version <= 0 OR p_dispute_window_hours NOT BETWEEN 0 AND 336
    OR p_effective_from IS NULL OR length(btrim(COALESCE(p_change_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_RULE_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_organization_id, p_actor_id,
    p_version, p_dispute_window_hours, p_effective_from, btrim(p_change_reason)), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':booking-rule:' || p_idempotency_key, 0));
  SELECT * INTO v_rule FROM booking_settlement_rules
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_rule.request_hash <> v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    SELECT id INTO v_approval FROM financial_approval_requests
    WHERE resource_type = 'booking_settlement_rule' AND resource_id = v_rule.id;
    RETURN jsonb_build_object('rule', to_jsonb(v_rule), 'approval_id', v_approval, 'idempotency_replay', TRUE);
  END IF;
  v_previous := current_setting('microfams.booking_rule_engine', TRUE);
  PERFORM set_config('microfams.booking_rule_engine', 'on', TRUE);
  INSERT INTO booking_settlement_rules(
    organization_id, version, dispute_window_hours, effective_from,
    change_reason, created_by, idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_version, p_dispute_window_hours, p_effective_from,
    btrim(p_change_reason), p_actor_id, p_idempotency_key, v_hash
  ) RETURNING * INTO v_rule;
  INSERT INTO financial_approval_requests(
    organization_id, action_type, resource_type, resource_id, requested_by, reason
  ) VALUES (
    p_organization_id, 'rule_activation', 'booking_settlement_rule',
    v_rule.id, p_actor_id, btrim(p_change_reason)
  ) RETURNING id INTO v_approval;
  PERFORM set_config('microfams.booking_rule_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object('rule', to_jsonb(v_rule), 'approval_id', v_approval, 'idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION propose_booking_fee_rule(
  p_organization_id UUID, p_actor_id UUID, p_version INTEGER, p_currency TEXT,
  p_payer TEXT, p_beneficiary_organization_id UUID, p_fixed_amount_minor BIGINT,
  p_basis_points INTEGER, p_minimum_amount_minor BIGINT, p_maximum_amount_minor BIGINT,
  p_tax_withholding_metadata JSONB, p_effective_from TIMESTAMPTZ,
  p_change_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_rule booking_fee_rules; v_hash TEXT; v_approval UUID; v_previous TEXT; v_currency TEXT := upper(p_currency);
BEGIN
  IF NOT has_financial_permission(p_organization_id, p_actor_id, 'financial.rules.propose')
  THEN RAISE EXCEPTION 'BOOKING_RULE_NOT_AUTHORIZED'; END IF;
  IF p_version IS NULL OR p_version <= 0 OR v_currency !~ '^[A-Z]{3}$'
    OR p_payer NOT IN ('customer', 'supplier') OR p_fixed_amount_minor < 0
    OR p_basis_points NOT BETWEEN 0 AND 10000 OR p_minimum_amount_minor < 0
    OR (p_maximum_amount_minor IS NOT NULL AND p_maximum_amount_minor < p_minimum_amount_minor)
    OR jsonb_typeof(COALESCE(p_tax_withholding_metadata, 'null'::JSONB)) <> 'object'
    OR p_effective_from IS NULL OR length(btrim(COALESCE(p_change_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_RULE_INVALID'; END IF;
  IF (p_fixed_amount_minor > 0 OR p_basis_points > 0 OR p_minimum_amount_minor > 0
      OR COALESCE(p_maximum_amount_minor, 0) > 0)
    AND p_payer <> 'supplier'
  THEN RAISE EXCEPTION 'BOOKING_CUSTOMER_FEE_REQUIRES_PREPAYMENT'; END IF;
  IF (p_fixed_amount_minor > 0 OR p_basis_points > 0 OR p_minimum_amount_minor > 0
      OR COALESCE(p_maximum_amount_minor, 0) > 0)
    AND (p_beneficiary_organization_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM organizations WHERE id = p_beneficiary_organization_id AND status = 'active'
    ))
  THEN RAISE EXCEPTION 'BOOKING_FEE_BENEFICIARY_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_organization_id, p_actor_id,
    p_version, v_currency, p_payer, p_beneficiary_organization_id,
    p_fixed_amount_minor, p_basis_points, p_minimum_amount_minor, p_maximum_amount_minor,
    p_tax_withholding_metadata::TEXT, p_effective_from, btrim(p_change_reason)), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':booking-fee-rule:' || p_idempotency_key, 0));
  SELECT * INTO v_rule FROM booking_fee_rules
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_rule.request_hash <> v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    SELECT id INTO v_approval FROM financial_approval_requests
    WHERE resource_type = 'booking_fee_rule' AND resource_id = v_rule.id;
    RETURN jsonb_build_object('rule', to_jsonb(v_rule), 'approval_id', v_approval, 'idempotency_replay', TRUE);
  END IF;
  v_previous := current_setting('microfams.booking_rule_engine', TRUE);
  PERFORM set_config('microfams.booking_rule_engine', 'on', TRUE);
  INSERT INTO booking_fee_rules(
    organization_id, beneficiary_organization_id, version, currency, payer,
    fixed_amount_minor, basis_points, minimum_amount_minor, maximum_amount_minor,
    tax_withholding_metadata, effective_from, change_reason, created_by,
    idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_beneficiary_organization_id, p_version, v_currency, p_payer,
    p_fixed_amount_minor, p_basis_points, p_minimum_amount_minor, p_maximum_amount_minor,
    p_tax_withholding_metadata, p_effective_from, btrim(p_change_reason), p_actor_id,
    p_idempotency_key, v_hash
  ) RETURNING * INTO v_rule;
  INSERT INTO financial_approval_requests(
    organization_id, action_type, resource_type, resource_id, requested_by, reason
  ) VALUES (
    p_organization_id, 'rule_activation', 'booking_fee_rule',
    v_rule.id, p_actor_id, btrim(p_change_reason)
  ) RETURNING id INTO v_approval;
  PERFORM set_config('microfams.booking_rule_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object('rule', to_jsonb(v_rule), 'approval_id', v_approval, 'idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_financial_rule(
  p_approval_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_approve BOOLEAN, p_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_request financial_approval_requests;
  v_settlement booking_settlement_rules;
  v_fee booking_fee_rules;
  v_previous TEXT;
  v_hash TEXT;
BEGIN
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
  THEN RAISE EXCEPTION 'BOOKING_RULE_DECISION_REASON_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_approval_id, p_organization_id,
    p_actor_id, p_approve, btrim(p_reason)), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':booking-rule-decision:' || p_idempotency_key, 0));
  SELECT * INTO v_request FROM financial_approval_requests
  WHERE id = p_approval_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND OR v_request.action_type <> 'rule_activation'
    OR v_request.resource_type NOT IN ('booking_settlement_rule', 'booking_fee_rule')
  THEN RAISE EXCEPTION 'BOOKING_RULE_APPROVAL_NOT_FOUND'; END IF;
  IF v_request.decision_idempotency_key IS NOT NULL THEN
    IF v_request.decision_idempotency_key <> p_idempotency_key
      OR v_request.decision_request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'approval_id', v_request.id, 'state', v_request.state,
      'resource_type', v_request.resource_type, 'resource_id', v_request.resource_id,
      'idempotency_replay', TRUE
    );
  END IF;
  IF v_request.state <> 'pending' THEN RAISE EXCEPTION 'BOOKING_RULE_APPROVAL_NOT_FOUND'; END IF;
  IF v_request.requested_by = p_actor_id THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  IF NOT has_financial_permission(v_request.organization_id, p_actor_id, 'financial.rules.approve')
  THEN RAISE EXCEPTION 'BOOKING_RULE_NOT_AUTHORIZED'; END IF;
  v_previous := current_setting('microfams.booking_rule_engine', TRUE);
  PERFORM set_config('microfams.booking_rule_engine', 'on', TRUE);
  IF v_request.resource_type = 'booking_settlement_rule' THEN
    SELECT * INTO v_settlement FROM booking_settlement_rules
    WHERE id = v_request.resource_id AND organization_id = v_request.organization_id FOR UPDATE;
    IF NOT FOUND OR v_settlement.status <> 'pending_approval' THEN
      RAISE EXCEPTION 'BOOKING_RULE_APPROVAL_NOT_FOUND';
    END IF;
    IF p_approve THEN
      IF EXISTS (SELECT 1 FROM booking_settlement_rules
        WHERE organization_id = v_settlement.organization_id AND status = 'active'
          AND effective_from >= v_settlement.effective_from)
      THEN RAISE EXCEPTION 'BOOKING_RULE_EFFECTIVE_WINDOW_CONFLICT'; END IF;
      UPDATE booking_settlement_rules SET status = 'retired',
        effective_until = v_settlement.effective_from
      WHERE organization_id = v_settlement.organization_id AND status = 'active'
        AND effective_from < v_settlement.effective_from
        AND (effective_until IS NULL OR effective_until > v_settlement.effective_from);
    END IF;
    UPDATE booking_settlement_rules SET
      status = CASE WHEN p_approve THEN 'active' ELSE 'rejected' END,
      approved_by = CASE WHEN p_approve THEN p_actor_id ELSE NULL END,
      approved_at = CASE WHEN p_approve THEN NOW() ELSE NULL END
    WHERE id = v_settlement.id;
  ELSE
    SELECT * INTO v_fee FROM booking_fee_rules
    WHERE id = v_request.resource_id AND organization_id = v_request.organization_id FOR UPDATE;
    IF NOT FOUND OR v_fee.status <> 'pending_approval' THEN
      RAISE EXCEPTION 'BOOKING_RULE_APPROVAL_NOT_FOUND';
    END IF;
    IF p_approve THEN
      IF EXISTS (SELECT 1 FROM booking_fee_rules
        WHERE organization_id = v_fee.organization_id AND currency = v_fee.currency
          AND status = 'active' AND effective_from >= v_fee.effective_from)
      THEN RAISE EXCEPTION 'BOOKING_RULE_EFFECTIVE_WINDOW_CONFLICT'; END IF;
      UPDATE booking_fee_rules SET status = 'retired', effective_until = v_fee.effective_from
      WHERE organization_id = v_fee.organization_id AND currency = v_fee.currency
        AND status = 'active' AND effective_from < v_fee.effective_from
        AND (effective_until IS NULL OR effective_until > v_fee.effective_from);
    END IF;
    UPDATE booking_fee_rules SET
      status = CASE WHEN p_approve THEN 'active' ELSE 'rejected' END,
      approved_by = CASE WHEN p_approve THEN p_actor_id ELSE NULL END,
      approved_at = CASE WHEN p_approve THEN NOW() ELSE NULL END
    WHERE id = v_fee.id;
  END IF;
  UPDATE financial_approval_requests SET
    state = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    decided_by = p_actor_id, decided_at = NOW(), reason = btrim(p_reason),
    decision_idempotency_key = p_idempotency_key, decision_request_hash = v_hash
  WHERE id = v_request.id;
  PERFORM set_config('microfams.booking_rule_engine', COALESCE(v_previous, ''), TRUE);
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_request.organization_id, p_actor_id,
    CASE WHEN p_approve THEN 'booking.rule.approved' ELSE 'booking.rule.rejected' END,
    v_request.resource_type, v_request.resource_id::TEXT,
    jsonb_build_object('approval_id', v_request.id, 'reason', btrim(p_reason))
  );
  RETURN jsonb_build_object('approval_id', v_request.id,
    'state', CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    'resource_type', v_request.resource_type, 'resource_id', v_request.resource_id,
    'idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION snapshot_booking_settlement_completion() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_timezone TEXT;
  v_rule booking_settlement_rules;
  v_fee booking_fee_rules;
  v_refunded BIGINT;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = NEW.booking_id FOR UPDATE;
  IF NOT FOUND OR v_contract.completed_at IS NOT NULL THEN RETURN NEW; END IF;
  SELECT timezone INTO v_timezone FROM organizations WHERE id = v_contract.provider_organization_id;
  SELECT * INTO v_rule FROM booking_settlement_rules
  WHERE organization_id = v_contract.organization_id AND status = 'active'
    AND effective_from <= NEW.created_at
    AND (effective_until IS NULL OR effective_until > NEW.created_at)
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_RULE_UNAVAILABLE'; END IF;
  SELECT * INTO v_fee FROM booking_fee_rules
  WHERE organization_id = v_contract.organization_id AND currency = v_contract.currency
    AND status = 'active' AND effective_from <= v_contract.funded_at
    AND (effective_until IS NULL OR effective_until > v_contract.funded_at)
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_FEE_RULE_UNAVAILABLE'; END IF;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id AND allocation_type = 'refund' AND state = 'final';
  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  UPDATE booking_settlement_contracts SET
    completion_transition_id = NEW.id,
    completed_at = NEW.created_at,
    dispute_deadline_at = NEW.created_at + make_interval(hours => v_rule.dispute_window_hours),
    settlement_timezone = COALESCE(v_timezone, 'Africa/Lagos'),
    settlement_rule_id = v_rule.id,
    fee_rule_id = v_fee.id,
    state = CASE WHEN state IN ('refunded', 'reversed', 'manual_review')
      THEN state ELSE 'completed_pending_window' END,
    eligibility_snapshot = jsonb_build_object(
      'completion_time', NEW.created_at,
      'timezone', COALESCE(v_timezone, 'Africa/Lagos'),
      'dispute_window_hours', v_rule.dispute_window_hours,
      'dispute_deadline', NEW.created_at + make_interval(hours => v_rule.dispute_window_hours),
      'settlement_rule_version', v_rule.version,
      'fee_rule_version', v_fee.version,
      'fee_rule', jsonb_build_object(
        'payer', v_fee.payer, 'currency', v_fee.currency,
        'fixed_amount_minor', v_fee.fixed_amount_minor,
        'basis_points', v_fee.basis_points,
        'minimum_amount_minor', v_fee.minimum_amount_minor,
        'maximum_amount_minor', v_fee.maximum_amount_minor,
        'beneficiary_organization_id', v_fee.beneficiary_organization_id,
        'tax_withholding_metadata', v_fee.tax_withholding_metadata
      ),
      'gross_amount_minor', v_contract.gross_amount_minor,
      'refunded_amount_minor', v_refunded,
      'payout_destination_fingerprint', NULL
    ),
    updated_at = NOW()
  WHERE id = v_contract.id;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);
  RETURN NEW;
END;
$$;
CREATE TRIGGER snapshot_booking_settlement_completion_trigger
  AFTER INSERT ON booking_state_transitions
  FOR EACH ROW WHEN (NEW.to_status = 'completed')
  EXECUTE FUNCTION snapshot_booking_settlement_completion();

CREATE OR REPLACE FUNCTION resolve_booking_accounting_actor(
  p_organization_id UUID, p_preferred_actor_id UUID
) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_actor UUID;
BEGIN
  SELECT membership.user_id INTO v_actor
  FROM organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active'
    AND (
      membership.role = 'owner'
      OR 'financial.journals.post' = ANY(membership.permissions)
      OR 'financial.*' = ANY(membership.permissions)
    )
  ORDER BY
    (membership.user_id = p_preferred_actor_id) DESC,
    CASE membership.role
      WHEN 'owner' THEN 1
      WHEN 'finance_manager' THEN 2
      WHEN 'admin' THEN 3
      ELSE 4
    END,
    membership.created_at,
    membership.user_id
  LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_ACCOUNTING_ACTOR_UNAVAILABLE';
  END IF;
  RETURN v_actor;
END;
$$;

CREATE OR REPLACE FUNCTION ensure_booking_settlement_account(
  p_organization_id UUID, p_counterparty_id UUID, p_actor_id UUID,
  p_purpose TEXT, p_currency TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rule financial_account_purpose_rules;
  v_account UUID;
  v_owner_type TEXT;
  v_owner_id UUID;
  v_code TEXT;
  v_accounting_actor UUID;
BEGIN
  v_accounting_actor := resolve_booking_accounting_actor(p_organization_id, p_actor_id);
  SELECT * INTO v_rule FROM financial_account_purpose_rules WHERE purpose = p_purpose;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ACCOUNT_PURPOSE_INVALID'; END IF;
  IF p_purpose IN (
    'interorganization_settlement_due_to', 'interorganization_settlement_due_from',
    'supplier_booking_service_revenue'
  ) THEN v_owner_type := 'provider'; v_owner_id := p_counterparty_id;
  ELSE v_owner_type := 'system'; v_owner_id := NULL;
  END IF;
  IF NOT v_owner_type = ANY(v_rule.allowed_owner_types) THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_ACCOUNT_OWNER_INVALID';
  END IF;
  v_code := upper(substr(replace(p_purpose, '_', '.'), 1, 23))
    || '.' || upper(substr(md5(COALESCE(p_counterparty_id::TEXT, p_purpose)), 1, 16));
  INSERT INTO financial_accounts(
    organization_id, code, name, account_class, normal_side, currency,
    owner_type, owner_id, is_control, status, created_by, purpose, effective_from
  ) VALUES (
    p_organization_id, v_code, initcap(replace(p_purpose, '_', ' ')),
    v_rule.account_class, v_rule.normal_side, upper(p_currency),
    v_owner_type, v_owner_id, v_rule.is_control, 'active', v_accounting_actor,
    p_purpose, CURRENT_DATE
  ) ON CONFLICT DO NOTHING;
  SELECT id INTO v_account FROM financial_accounts
  WHERE organization_id = p_organization_id AND purpose = p_purpose
    AND owner_type = v_owner_type AND owner_id IS NOT DISTINCT FROM v_owner_id
    AND currency = upper(p_currency) AND effective_until IS NULL AND status = 'active';
  IF v_account IS NULL THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ACCOUNT_UNAVAILABLE'; END IF;
  RETURN v_account;
END;
$$;

CREATE OR REPLACE FUNCTION post_booking_settlement_journal(
  p_organization_id UUID, p_actor_id UUID, p_currency TEXT,
  p_source_domain TEXT, p_source_record_id TEXT, p_idempotency_key TEXT,
  p_correlation_id UUID, p_description TEXT, p_lines JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_hash TEXT; v_accounting_actor UUID;
BEGIN
  v_accounting_actor := resolve_booking_accounting_actor(p_organization_id, p_actor_id);
  v_hash := encode(digest(convert_to(concat_ws('|', p_organization_id,
    p_source_domain, p_source_record_id, p_idempotency_key, p_correlation_id,
    p_description, p_lines::TEXT), 'UTF8'), 'sha256'), 'hex');
  RETURN post_financial_journal(
    p_organization_id, p_currency, CURRENT_DATE, p_source_domain,
    p_source_record_id, p_idempotency_key, v_hash, p_correlation_id,
    p_description, v_accounting_actor, p_lines
  );
END;
$$;

CREATE OR REPLACE FUNCTION release_booking_settlement(
  p_booking_id UUID, p_acting_organization_id UUID, p_actor_id UUID,
  p_idempotency_key TEXT, p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_booking bookings;
  v_payment payments;
  v_fee booking_fee_rules;
  v_hash TEXT;
  v_previous TEXT;
  v_refunded BIGINT;
  v_contested BIGINT;
  v_reversed BIGINT;
  v_available BIGINT;
  v_fee_delta BIGINT;
  v_supplier_delta BIGINT;
  v_release_id UUID := gen_random_uuid();
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
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REQUEST_INVALID'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_booking_id,
    p_acting_organization_id, p_actor_id, p_correlation_id), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended('booking-release:' || p_booking_id::TEXT, 0));
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND'; END IF;
  IF v_contract.release_idempotency_key IS NOT NULL THEN
    IF v_contract.release_idempotency_key <> p_idempotency_key OR v_contract.release_request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object('settlement', to_jsonb(v_contract), 'idempotency_replay', TRUE);
  END IF;
  IF p_acting_organization_id <> v_contract.organization_id
    OR NOT has_booking_permission(p_acting_organization_id, p_actor_id, 'booking.settlements.release')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_booking FROM bookings WHERE id = v_contract.booking_id FOR UPDATE;
  SELECT * INTO v_payment FROM payments WHERE id = v_contract.payment_id FOR UPDATE;
  IF v_booking.status <> 'completed' OR v_contract.completed_at IS NULL
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_COMPLETED'; END IF;
  IF NOW() < v_contract.dispute_deadline_at
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_DISPUTE_WINDOW_OPEN'; END IF;
  IF v_payment.state NOT IN ('succeeded', 'partially_refunded')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_PAYMENT_NOT_ELIGIBLE'; END IF;
  IF EXISTS (SELECT 1 FROM organizations
    WHERE id IN (v_contract.organization_id, v_contract.provider_organization_id)
      AND status <> 'active')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ORGANIZATION_INACTIVE'; END IF;
  IF EXISTS (SELECT 1 FROM organization_suspensions
    WHERE organization_id IN (v_contract.organization_id, v_contract.provider_organization_id)
      AND status = 'active')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_ORGANIZATION_SUSPENDED'; END IF;
  IF EXISTS (SELECT 1 FROM data_legal_holds
    WHERE status = 'active' AND subject_type = 'organization'
      AND subject_id IN (v_contract.organization_id::TEXT, v_contract.provider_organization_id::TEXT))
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_LEGAL_HOLD'; END IF;
  IF EXISTS (SELECT 1 FROM financial_risk_controls
    WHERE organization_id IN (v_contract.organization_id, v_contract.provider_organization_id)
      AND released_at IS NULL AND effective_from <= NOW()
      AND (effective_until IS NULL OR effective_until > NOW())
      AND product IN ('*', 'booking', 'booking_settlement')
      AND subject_type = 'organization' AND subject_id = organization_id::TEXT)
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_RISK_HOLD'; END IF;
  IF EXISTS (SELECT 1 FROM booking_settlement_holds
    WHERE settlement_contract_id = v_contract.id AND state = 'active')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_HOLD_ACTIVE'; END IF;
  IF EXISTS (SELECT 1 FROM payment_refunds
    WHERE payment_id = v_payment.id AND state IN ('created', 'submitted', 'processing'))
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REFUND_PENDING'; END IF;
  IF EXISTS (SELECT 1 FROM payment_refunds
    WHERE payment_id = v_payment.id AND state = 'failed')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REFUND_REVIEW_REQUIRED'; END IF;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_reversed
  FROM booking_settlement_allocations WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'reversal' AND state = 'final';
  IF v_reversed > 0 THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_REVERSED'; END IF;
  v_available := v_contract.gross_amount_minor - v_refunded - v_contested;
  IF v_available <= 0 THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NO_RELEASABLE_AMOUNT'; END IF;

  SELECT * INTO v_fee FROM booking_fee_rules WHERE id = v_contract.fee_rule_id;
  IF NOT FOUND OR v_fee.status NOT IN ('active', 'retired') OR v_fee.currency <> v_contract.currency
  THEN RAISE EXCEPTION 'BOOKING_FEE_RULE_UNAVAILABLE'; END IF;
  IF (v_fee.fixed_amount_minor > 0 OR v_fee.basis_points > 0
      OR v_fee.minimum_amount_minor > 0 OR COALESCE(v_fee.maximum_amount_minor, 0) > 0)
    AND NOT EXISTS (SELECT 1 FROM organizations
      WHERE id = v_fee.beneficiary_organization_id AND status = 'active')
  THEN RAISE EXCEPTION 'BOOKING_FEE_BENEFICIARY_INVALID'; END IF;
  v_fee_delta := calculate_booking_fee_minor(
    v_available, v_fee.fixed_amount_minor, v_fee.basis_points,
    v_fee.minimum_amount_minor, v_fee.maximum_amount_minor
  );
  v_supplier_delta := v_available - v_fee_delta;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_contract.escrow_account_id, 'line_number', 1,
      'side', 'debit', 'amount_minor', v_available, 'memo', 'Release eligible booking escrow')
  );
  IF v_supplier_delta > 0 THEN
    v_due_to_provider := ensure_booking_settlement_account(
      v_contract.organization_id, v_contract.provider_organization_id, p_actor_id,
      'interorganization_settlement_due_to', v_contract.currency
    );
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_due_to_provider, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_supplier_delta, 'memo', 'Supplier proceeds due'));
  END IF;
  IF v_fee_delta > 0 THEN
    v_platform_payable := ensure_booking_settlement_account(
      v_contract.organization_id, v_fee.beneficiary_organization_id, p_actor_id,
      'platform_fee_payable', v_contract.currency
    );
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_platform_payable, 'line_number', 3, 'side', 'credit',
      'amount_minor', v_fee_delta, 'memo', 'Platform booking fee due'));
  END IF;
  v_customer_journal := post_booking_settlement_journal(
    v_contract.organization_id, p_actor_id, v_contract.currency,
    'booking.settlement.release', v_release_id::TEXT,
    'booking.release.customer:' || p_idempotency_key, p_correlation_id,
    'Release eligible booking escrow', v_lines
  );

  v_previous := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  IF v_supplier_delta > 0 THEN
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id, journal_entry_id
    ) VALUES (
      v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
      'supplier', 'final', v_supplier_delta, v_contract.currency,
      'supplier_release', v_release_id, v_customer_journal
    ) RETURNING id INTO v_supplier_allocation;
    v_provider_due_from := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.organization_id, p_actor_id,
      'interorganization_settlement_due_from', v_contract.currency);
    v_supplier_revenue := ensure_booking_settlement_account(
      v_contract.provider_organization_id, v_contract.provider_organization_id, p_actor_id,
      'supplier_booking_service_revenue', v_contract.currency);
    v_provider_journal := post_booking_settlement_journal(
      v_contract.provider_organization_id, p_actor_id, v_contract.currency,
      'booking.settlement.provider_recognition', v_release_id::TEXT,
      'booking.release.provider:' || p_idempotency_key, p_correlation_id,
      'Recognize supplier booking proceeds',
      jsonb_build_array(
        jsonb_build_object('account_id', v_provider_due_from, 'line_number', 1,
          'side', 'debit', 'amount_minor', v_supplier_delta,
          'memo', 'Settlement due from customer organization'),
        jsonb_build_object('account_id', v_supplier_revenue, 'line_number', 2,
          'side', 'credit', 'amount_minor', v_supplier_delta,
          'memo', 'Booking service revenue')
      )
    );
    INSERT INTO booking_settlement_posting_links(
      organization_id, settlement_contract_id, allocation_id, posting_role,
      journal_entry_id, correlation_id
    ) VALUES
      (v_contract.organization_id, v_contract.id, v_supplier_allocation,
        'customer_release', v_customer_journal, p_correlation_id),
      (v_contract.provider_organization_id, v_contract.id, v_supplier_allocation,
        'provider_recognition', v_provider_journal, p_correlation_id);
  END IF;
  IF v_fee_delta > 0 THEN
    INSERT INTO booking_settlement_allocations(
      organization_id, provider_organization_id, settlement_contract_id,
      allocation_type, state, amount_minor, currency, source_type, source_id, journal_entry_id
    ) VALUES (
      v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
      'platform_fee', 'final', v_fee_delta, v_contract.currency,
      'platform_fee', v_release_id, v_customer_journal
    ) RETURNING id INTO v_fee_allocation;
    v_platform_due_from := ensure_booking_settlement_account(
      v_fee.beneficiary_organization_id, v_contract.organization_id, p_actor_id,
      'interorganization_settlement_due_from', v_contract.currency);
    v_platform_revenue := ensure_booking_settlement_account(
      v_fee.beneficiary_organization_id, NULL, p_actor_id,
      'platform_booking_fee_revenue', v_contract.currency);
    v_platform_journal := post_booking_settlement_journal(
      v_fee.beneficiary_organization_id, p_actor_id, v_contract.currency,
      'booking.settlement.platform_recognition', v_release_id::TEXT,
      'booking.release.platform:' || p_idempotency_key, p_correlation_id,
      'Recognize platform booking fee',
      jsonb_build_array(
        jsonb_build_object('account_id', v_platform_due_from, 'line_number', 1,
          'side', 'debit', 'amount_minor', v_fee_delta,
          'memo', 'Platform fee due from settlement organization'),
        jsonb_build_object('account_id', v_platform_revenue, 'line_number', 2,
          'side', 'credit', 'amount_minor', v_fee_delta,
          'memo', 'Platform booking fee revenue')
      )
    );
    INSERT INTO booking_settlement_posting_links(
      organization_id, settlement_contract_id, allocation_id, posting_role,
      journal_entry_id, correlation_id
    ) VALUES
      (v_contract.organization_id, v_contract.id, v_fee_allocation,
        'customer_release', v_customer_journal, p_correlation_id),
      (v_fee.beneficiary_organization_id, v_contract.id, v_fee_allocation,
        'platform_recognition', v_platform_journal, p_correlation_id);
  END IF;

  UPDATE booking_settlement_contracts SET
    state = 'settled', eligible_at = NOW(), released_at = NOW(),
    supplier_amount_minor = v_supplier_delta,
    platform_fee_amount_minor = v_fee_delta,
    release_idempotency_key = p_idempotency_key,
    release_request_hash = v_hash,
    release_correlation_id = p_correlation_id,
    customer_release_journal_entry_id = v_customer_journal,
    provider_recognition_journal_entry_id = v_provider_journal,
    platform_recognition_journal_entry_id = v_platform_journal,
    eligibility_snapshot = COALESCE(eligibility_snapshot, '{}'::JSONB) || jsonb_build_object(
      'evaluated_at', NOW(), 'gross_amount_minor', gross_amount_minor,
      'refunded_amount_minor', v_refunded, 'contested_amount_minor', v_contested,
      'supplier_amount_minor', v_supplier_delta,
      'platform_fee_amount_minor', v_fee_delta,
      'payout_destination_fingerprint', NULL,
      'release_correlation_id', p_correlation_id
    ),
    updated_at = NOW()
  WHERE id = v_contract.id RETURNING * INTO v_contract;
  PERFORM set_config('microfams.booking_settlement_engine', COALESCE(v_previous, ''), TRUE);

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES
    (v_contract.organization_id, p_actor_id, 'booking.settlement.released',
      'booking_settlement', v_contract.id::TEXT,
      jsonb_build_object('booking_id', v_contract.booking_id,
        'supplier_amount_minor', v_supplier_delta, 'platform_fee_amount_minor', v_fee_delta,
        'correlation_id', p_correlation_id)),
    (v_contract.provider_organization_id, p_actor_id, 'booking.settlement.recognized',
      'booking_settlement', v_contract.id::TEXT,
      jsonb_build_object('booking_id', v_contract.booking_id,
        'supplier_amount_minor', v_supplier_delta, 'correlation_id', p_correlation_id));
  IF v_fee_delta > 0 THEN
    INSERT INTO organization_audit_log(
      organization_id, actor_id, action, resource_type, resource_id, after_value
    ) VALUES (
      v_fee.beneficiary_organization_id, p_actor_id, 'booking.fee.recognized',
      'booking_settlement', v_contract.id::TEXT,
      jsonb_build_object('booking_id', v_contract.booking_id,
        'platform_fee_amount_minor', v_fee_delta, 'correlation_id', p_correlation_id)
    );
  END IF;
  RETURN jsonb_build_object('settlement', to_jsonb(v_contract), 'idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_settlement_summary(
  p_booking_id UUID, p_acting_organization_id UUID, p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_contract booking_settlement_contracts; v_refunded BIGINT; v_contested BIGINT;
BEGIN
  SELECT * INTO v_contract FROM booking_settlement_contracts WHERE booking_id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND'; END IF;
  IF p_acting_organization_id NOT IN (v_contract.organization_id, v_contract.provider_organization_id)
    OR NOT has_booking_permission(p_acting_organization_id, p_actor_id, 'booking.settlements.read')
  THEN RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_AUTHORIZED'; END IF;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM booking_settlement_allocations WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'refund' AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  RETURN jsonb_build_object(
    'id', v_contract.id, 'booking_id', v_contract.booking_id,
    'customer_organization_id', v_contract.organization_id,
    'provider_organization_id', v_contract.provider_organization_id,
    'currency', v_contract.currency, 'state', v_contract.state,
    'gross_amount_minor', v_contract.gross_amount_minor,
    'refunded_amount_minor', v_refunded, 'contested_amount_minor', v_contested,
    'supplier_amount_minor', COALESCE(v_contract.supplier_amount_minor, 0),
    'platform_fee_amount_minor', COALESCE(v_contract.platform_fee_amount_minor, 0),
    'completed_at', v_contract.completed_at,
    'dispute_deadline_at', v_contract.dispute_deadline_at,
    'timezone', v_contract.settlement_timezone, 'released_at', v_contract.released_at,
    'eligibility_snapshot', v_contract.eligibility_snapshot
  );
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_financial_rules(
  p_organization_id UUID, p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (
    has_booking_permission(p_organization_id, p_actor_id, 'booking.settlements.read')
    OR has_financial_permission(p_organization_id, p_actor_id, 'financial.rules.propose')
    OR has_financial_permission(p_organization_id, p_actor_id, 'financial.rules.approve')
  ) THEN RAISE EXCEPTION 'BOOKING_RULE_NOT_AUTHORIZED'; END IF;
  RETURN jsonb_build_object(
    'settlement_rules', COALESCE((
      SELECT jsonb_agg(to_jsonb(rule) ORDER BY rule.version DESC)
      FROM booking_settlement_rules AS rule
      WHERE rule.organization_id = p_organization_id
    ), '[]'::JSONB),
    'fee_rules', COALESCE((
      SELECT jsonb_agg(to_jsonb(rule) ORDER BY rule.currency, rule.version DESC)
      FROM booking_fee_rules AS rule
      WHERE rule.organization_id = p_organization_id
    ), '[]'::JSONB),
    'pending_approvals', COALESCE((
      SELECT jsonb_agg(to_jsonb(approval) ORDER BY approval.requested_at)
      FROM financial_approval_requests AS approval
      WHERE approval.organization_id = p_organization_id
        AND approval.resource_type IN ('booking_settlement_rule', 'booking_fee_rule')
        AND approval.state = 'pending'
    ), '[]'::JSONB)
  );
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'booking.settlements.read', 'booking.settlements.release'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_settlement_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_fee_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_settlement_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_settlement_posting_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_settlement_rules, booking_fee_rules,
  booking_settlement_holds, booking_settlement_posting_links FROM anon, authenticated;
GRANT SELECT ON booking_settlement_rules, booking_fee_rules,
  booking_settlement_holds, booking_settlement_posting_links TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_settlement_rules, booking_fee_rules,
  booking_settlement_holds, booking_settlement_posting_links FROM service_role;

REVOKE ALL ON FUNCTION protect_booking_rule_records() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION protect_booking_settlement_extension_records() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION calculate_booking_fee_minor(BIGINT, BIGINT, INTEGER, BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_booking_fee_minor(BIGINT, BIGINT, INTEGER, BIGINT, BIGINT) TO service_role;
REVOKE ALL ON FUNCTION has_booking_permission(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION resolve_booking_accounting_actor(UUID, UUID) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION provision_default_booking_financial_rules() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION propose_booking_settlement_rule(UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_booking_settlement_rule(UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
REVOKE ALL ON FUNCTION propose_booking_fee_rule(UUID, UUID, INTEGER, TEXT, TEXT, UUID, BIGINT, INTEGER, BIGINT, BIGINT, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_booking_fee_rule(UUID, UUID, INTEGER, TEXT, TEXT, UUID, BIGINT, INTEGER, BIGINT, BIGINT, JSONB, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
REVOKE ALL ON FUNCTION decide_booking_financial_rule(UUID, UUID, UUID, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION decide_booking_financial_rule(UUID, UUID, UUID, BOOLEAN, TEXT, TEXT) TO service_role;
REVOKE ALL ON FUNCTION snapshot_booking_settlement_completion() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION ensure_booking_settlement_account(UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION post_booking_settlement_journal(UUID, UUID, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, JSONB) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION release_booking_settlement(UUID, UUID, UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION release_booking_settlement(UUID, UUID, UUID, TEXT, UUID) TO service_role;
REVOKE ALL ON FUNCTION read_booking_settlement_summary(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_booking_settlement_summary(UUID, UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION read_booking_financial_rules(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_booking_financial_rules(UUID, UUID) TO service_role;
