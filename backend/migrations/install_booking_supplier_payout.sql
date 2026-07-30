-- BS-08: provider-organization beneficiaries and booking supplier payouts.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS booking_payout_destination_change_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  version INTEGER NOT NULL CHECK (version > 0),
  change_window_hours INTEGER NOT NULL CHECK (change_window_hours BETWEEN 1 AND 168),
  status TEXT NOT NULL DEFAULT 'active'
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

CREATE TABLE IF NOT EXISTS booking_payout_beneficiaries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  beneficiary_user_id UUID REFERENCES users(id),
  destination_ciphertext TEXT NOT NULL
    CHECK (length(destination_ciphertext) BETWEEN 40 AND 4096),
  destination_fingerprint VARCHAR(64) NOT NULL
    CHECK (destination_fingerprint ~ '^[a-f0-9]{64}$'),
  destination_masked TEXT NOT NULL CHECK (length(destination_masked) BETWEEN 4 AND 80),
  account_name_masked TEXT NOT NULL CHECK (length(account_name_masked) BETWEEN 2 AND 120),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL
    CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  verification_reference TEXT NOT NULL CHECK (length(verification_reference) BETWEEN 4 AND 200),
  state TEXT NOT NULL CHECK (state IN (
    'pending_approval', 'verified', 'retired', 'rejected', 'suspended'
  )),
  supersedes_beneficiary_id UUID REFERENCES booking_payout_beneficiaries(id),
  change_rule_id UUID REFERENCES booking_payout_destination_change_rules(id),
  change_rule_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(change_rule_snapshot) = 'object'),
  proposed_by UUID NOT NULL REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  approval_reason TEXT CHECK (
    approval_reason IS NULL OR length(btrim(approval_reason)) BETWEEN 10 AND 1000
  ),
  approved_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  decision_idempotency_key TEXT,
  decision_request_hash VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  CHECK (
    (state = 'pending_approval' AND supersedes_beneficiary_id IS NOT NULL
      AND approved_at IS NULL)
    OR (state = 'verified' AND approved_at IS NOT NULL)
    OR state IN ('retired', 'rejected', 'suspended')
  ),
  CHECK (
    approved_by IS NULL OR supersedes_beneficiary_id IS NULL
      OR approved_by <> proposed_by
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_booking_payout_verified_beneficiary
  ON booking_payout_beneficiaries(
    organization_id, provider_name, provider_environment
  ) WHERE state = 'verified';
CREATE INDEX IF NOT EXISTS idx_booking_payout_beneficiary_fingerprint
  ON booking_payout_beneficiaries(
    organization_id, destination_fingerprint, created_at
  );

ALTER TABLE payouts
  ALTER COLUMN withdrawal_request_id DROP NOT NULL,
  ALTER COLUMN reservation_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS source_type TEXT NOT NULL DEFAULT 'wallet_withdrawal'
    CHECK (source_type IN ('wallet_withdrawal', 'booking_settlement')),
  ADD COLUMN IF NOT EXISTS source_id UUID,
  ADD COLUMN IF NOT EXISTS booking_settlement_release_id UUID
    REFERENCES booking_settlement_releases(id),
  ADD COLUMN IF NOT EXISTS booking_payout_beneficiary_id UUID
    REFERENCES booking_payout_beneficiaries(id);
UPDATE payouts SET
  source_type = 'wallet_withdrawal',
  source_id = withdrawal_request_id
WHERE source_id IS NULL;
ALTER TABLE payouts ALTER COLUMN source_id SET NOT NULL;
ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_source_shape;
ALTER TABLE payouts ADD CONSTRAINT payouts_source_shape CHECK (
  (
    source_type = 'wallet_withdrawal'
    AND withdrawal_request_id IS NOT NULL
    AND reservation_id IS NOT NULL
    AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL
    AND source_id = withdrawal_request_id
  )
  OR (
    source_type = 'booking_settlement'
    AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL
    AND booking_settlement_release_id IS NOT NULL
    AND booking_payout_beneficiary_id IS NOT NULL
    AND source_id = booking_settlement_release_id
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_payout_source
  ON payouts(organization_id, source_type, source_id);

CREATE OR REPLACE FUNCTION populate_payout_source_identity() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.source_id IS NULL AND NEW.withdrawal_request_id IS NOT NULL THEN
    NEW.source_type := 'wallet_withdrawal';
    NEW.source_id := NEW.withdrawal_request_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS payouts_source_identity_defaults ON payouts;
CREATE TRIGGER payouts_source_identity_defaults
  BEFORE INSERT ON payouts
  FOR EACH ROW EXECUTE FUNCTION populate_payout_source_identity();

CREATE TABLE IF NOT EXISTS booking_supplier_payout_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  customer_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  settlement_release_id UUID NOT NULL UNIQUE REFERENCES booking_settlement_releases(id),
  payout_id UUID NOT NULL UNIQUE REFERENCES payouts(id),
  beneficiary_id UUID NOT NULL REFERENCES booking_payout_beneficiaries(id),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'reserved'
    CHECK (state IN ('reserved', 'processing', 'paid', 'restored')),
  destination_fingerprint VARCHAR(64) NOT NULL
    CHECK (destination_fingerprint ~ '^[a-f0-9]{64}$'),
  destination_masked TEXT NOT NULL CHECK (length(destination_masked) BETWEEN 4 AND 80),
  provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL,
  customer_journal_entry_id UUID REFERENCES journal_entries(id),
  provider_journal_entry_id UUID REFERENCES journal_entries(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_by UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  terminal_at TIMESTAMPTZ,
  UNIQUE (organization_id, idempotency_key),
  CHECK (
    (state IN ('paid', 'restored')) = (terminal_at IS NOT NULL)
  )
);

INSERT INTO financial_account_purpose_rules(
  purpose, account_class, normal_side, is_control, allowed_owner_types
) VALUES
  (
    'booking_payout_provider_clearing', 'asset', 'debit', TRUE,
    ARRAY['system']
  ),
  (
    'supplier_external_bank_asset', 'asset', 'debit', FALSE,
    ARRAY['system']
  )
ON CONFLICT (purpose) DO NOTHING;

CREATE OR REPLACE FUNCTION protect_booking_payout_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_payout_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking payout records can only be changed by the booking payout engine';
END;
$$;

DROP TRIGGER IF EXISTS booking_payout_change_rules_engine_only
  ON booking_payout_destination_change_rules;
CREATE TRIGGER booking_payout_change_rules_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_payout_destination_change_rules
  FOR EACH ROW EXECUTE FUNCTION protect_booking_payout_records();
DROP TRIGGER IF EXISTS booking_payout_beneficiaries_engine_only
  ON booking_payout_beneficiaries;
CREATE TRIGGER booking_payout_beneficiaries_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_payout_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION protect_booking_payout_records();
DROP TRIGGER IF EXISTS booking_supplier_payout_items_engine_only
  ON booking_supplier_payout_items;
CREATE TRIGGER booking_supplier_payout_items_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_supplier_payout_items
  FOR EACH ROW EXECUTE FUNCTION protect_booking_payout_records();

CREATE OR REPLACE FUNCTION sync_booking_supplier_payout_item_state()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_previous TEXT;
BEGIN
  IF NEW.source_type <> 'booking_settlement'
    OR NEW.state NOT IN ('submitted', 'processing')
    OR OLD.state IS NOT DISTINCT FROM NEW.state
  THEN RETURN NEW; END IF;
  v_previous := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  UPDATE booking_supplier_payout_items
  SET state = 'processing', updated_at = NOW()
  WHERE payout_id = NEW.id AND state = 'reserved';
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS sync_booking_supplier_payout_item_state_trigger
  ON payouts;
CREATE TRIGGER sync_booking_supplier_payout_item_state_trigger
  AFTER UPDATE OF state ON payouts
  FOR EACH ROW EXECUTE FUNCTION sync_booking_supplier_payout_item_state();

DO $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  INSERT INTO booking_payout_destination_change_rules(
    organization_id, version, change_window_hours, status, effective_from,
    change_reason, idempotency_key, request_hash
  )
  SELECT
    organization.id, 1, 24, 'active', '-infinity',
    'Approved BS-08 default destination-change control window.',
    'default-bs08-change-rule',
    encode(digest(convert_to(
      organization.id::TEXT || '|BS08|1|24', 'UTF8'
    ), 'sha256'), 'hex')
  FROM organizations AS organization
  ON CONFLICT (organization_id, version) DO NOTHING;
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous, ''), TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION provision_default_booking_payout_change_rule()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  INSERT INTO booking_payout_destination_change_rules(
    organization_id, version, change_window_hours, status, effective_from,
    change_reason, idempotency_key, request_hash
  ) VALUES (
    NEW.id, 1, 24, 'active', '-infinity',
    'Approved BS-08 default destination-change control window.',
    'default-bs08-change-rule',
    encode(digest(convert_to(
      NEW.id::TEXT || '|BS08|1|24', 'UTF8'
    ), 'sha256'), 'hex')
  ) ON CONFLICT (organization_id, version) DO NOTHING;
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS provision_default_booking_payout_change_rule_trigger
  ON organizations;
CREATE TRIGGER provision_default_booking_payout_change_rule_trigger
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION provision_default_booking_payout_change_rule();

CREATE OR REPLACE FUNCTION propose_booking_payout_change_rule(
  p_organization_id UUID,
  p_actor_id UUID,
  p_version INTEGER,
  p_change_window_hours INTEGER,
  p_effective_from TIMESTAMPTZ,
  p_change_reason TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_existing booking_payout_destination_change_rules;
  v_rule booking_payout_destination_change_rules;
  v_hash TEXT;
  v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_actor_id IS NULL
    OR COALESCE(p_version, 0) <= 0
    OR p_change_window_hours NOT BETWEEN 1 AND 168
    OR p_effective_from IS NULL
    OR length(btrim(COALESCE(p_change_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'financial.payouts.rules.propose'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id, p_actor_id, p_version, p_change_window_hours,
    p_effective_from, btrim(p_change_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_payout_destination_change_rules
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
    SELECT 1 FROM booking_payout_destination_change_rules
    WHERE organization_id = p_organization_id AND version = p_version
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_VERSION_CONFLICT'; END IF;
  v_previous := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  INSERT INTO booking_payout_destination_change_rules(
    organization_id, version, change_window_hours, effective_from,
    change_reason, created_by, idempotency_key, request_hash, status
  ) VALUES (
    p_organization_id, p_version, p_change_window_hours, p_effective_from,
    btrim(p_change_reason), p_actor_id, p_idempotency_key, v_hash,
    'pending_approval'
  ) RETURNING * INTO v_rule;
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN jsonb_build_object(
    'rule_id', v_rule.id, 'state', v_rule.status,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_payout_change_rule(
  p_rule_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_rule booking_payout_destination_change_rules;
  v_hash TEXT;
  v_previous TEXT;
BEGIN
  IF p_rule_id IS NULL OR p_organization_id IS NULL OR p_actor_id IS NULL
    OR p_approve IS NULL
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_DECISION_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'financial.payouts.rules.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_rule FROM booking_payout_destination_change_rules
  WHERE id = p_rule_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_NOT_FOUND'; END IF;
  IF v_rule.created_by = p_actor_id
  THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_rule_id, p_organization_id, p_actor_id, p_approve, btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  IF v_rule.status <> 'pending_approval' THEN
    IF v_rule.decision_idempotency_key = p_idempotency_key
      AND v_rule.decision_request_hash = v_hash
    THEN RETURN jsonb_build_object(
      'rule_id', v_rule.id, 'state', v_rule.status,
      'idempotency_replay', TRUE
    ); END IF;
    RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_DECIDED';
  END IF;
  v_previous := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  IF p_approve THEN
    UPDATE booking_payout_destination_change_rules
    SET effective_until = v_rule.effective_from
    WHERE organization_id = v_rule.organization_id AND status = 'active'
      AND effective_from < v_rule.effective_from
      AND (effective_until IS NULL OR effective_until > v_rule.effective_from);
  END IF;
  UPDATE booking_payout_destination_change_rules SET
    status = CASE WHEN p_approve THEN 'active' ELSE 'rejected' END,
    approved_by = p_actor_id, approved_at = NOW(),
    decision_idempotency_key = p_idempotency_key,
    decision_request_hash = v_hash
  WHERE id = v_rule.id RETURNING * INTO v_rule;
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous, ''), TRUE
  );
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    p_organization_id, p_actor_id,
    CASE WHEN p_approve
      THEN 'booking.payout_change_rule.approved'
      ELSE 'booking.payout_change_rule.rejected' END,
    'booking_payout_destination_change_rule', v_rule.id::TEXT,
    jsonb_build_object(
      'version', v_rule.version,
      'change_window_hours', v_rule.change_window_hours,
      'reason', btrim(p_reason)
    )
  );
  RETURN jsonb_build_object(
    'rule_id', v_rule.id, 'state', v_rule.status,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION register_booking_payout_beneficiary(
  p_organization_id UUID,
  p_actor_id UUID,
  p_beneficiary_user_id UUID,
  p_destination_ciphertext TEXT,
  p_destination_fingerprint TEXT,
  p_destination_masked TEXT,
  p_account_name_masked TEXT,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_verification_reference TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_existing booking_payout_beneficiaries;
  v_current booking_payout_beneficiaries;
  v_rule booking_payout_destination_change_rules;
  v_result booking_payout_beneficiaries;
  v_hash TEXT;
  v_previous_booking TEXT;
  v_previous_settlement TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_actor_id IS NULL
    OR length(COALESCE(p_destination_ciphertext, '')) NOT BETWEEN 40 AND 4096
    OR p_destination_fingerprint !~ '^[a-f0-9]{64}$'
    OR length(COALESCE(p_destination_masked, '')) NOT BETWEEN 4 AND 80
    OR length(COALESCE(p_account_name_masked, '')) NOT BETWEEN 2 AND 120
    OR p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic', 'sandbox', 'live')
    OR length(COALESCE(p_verification_reference, '')) NOT BETWEEN 4 AND 200
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'financial.payouts.create'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  IF p_beneficiary_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_beneficiary_user_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_MEMBERSHIP_INVALID'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id, p_actor_id, p_beneficiary_user_id,
    p_destination_ciphertext, p_destination_fingerprint,
    p_destination_masked, p_account_name_masked,
    p_provider_name, p_provider_environment, p_verification_reference
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_payout_beneficiaries
  WHERE organization_id = p_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'beneficiary_id', v_existing.id, 'state', v_existing.state,
      'destination_masked', v_existing.destination_masked,
      'idempotency_replay', TRUE
    );
  END IF;
  SELECT * INTO v_current FROM booking_payout_beneficiaries
  WHERE organization_id = p_organization_id
    AND provider_name = p_provider_name
    AND provider_environment = p_provider_environment
    AND state = 'verified'
  FOR UPDATE;
  IF FOUND AND v_current.destination_fingerprint = p_destination_fingerprint THEN
    RETURN jsonb_build_object(
      'beneficiary_id', v_current.id, 'state', v_current.state,
      'destination_masked', v_current.destination_masked,
      'idempotency_replay', TRUE
    );
  END IF;
  SELECT * INTO v_rule FROM booking_payout_destination_change_rules
  WHERE organization_id = p_organization_id AND status = 'active'
    AND effective_from <= NOW()
    AND (effective_until IS NULL OR effective_until > NOW())
  ORDER BY effective_from DESC, version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_PAYOUT_CHANGE_RULE_UNAVAILABLE'; END IF;

  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  v_previous_settlement := current_setting(
    'microfams.booking_settlement_engine', TRUE
  );
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  INSERT INTO booking_payout_beneficiaries(
    organization_id, beneficiary_user_id, destination_ciphertext,
    destination_fingerprint, destination_masked, account_name_masked,
    provider_name, provider_environment, verification_reference, state,
    supersedes_beneficiary_id, change_rule_id, change_rule_snapshot,
    proposed_by, approved_by, approved_at, idempotency_key, request_hash
  ) VALUES (
    p_organization_id, p_beneficiary_user_id, p_destination_ciphertext,
    p_destination_fingerprint, p_destination_masked, p_account_name_masked,
    p_provider_name, p_provider_environment, p_verification_reference,
    CASE WHEN v_current.id IS NULL THEN 'verified' ELSE 'pending_approval' END,
    v_current.id, v_rule.id,
    jsonb_build_object(
      'rule_id', v_rule.id, 'version', v_rule.version,
      'change_window_hours', v_rule.change_window_hours
    ),
    p_actor_id,
    CASE WHEN v_current.id IS NULL THEN p_actor_id ELSE NULL END,
    CASE WHEN v_current.id IS NULL THEN NOW() ELSE NULL END,
    p_idempotency_key, v_hash
  ) RETURNING * INTO v_result;

  IF v_current.id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM booking_settlement_contracts AS contract
    WHERE contract.provider_organization_id = p_organization_id
      AND contract.funded_at IS NOT NULL
      AND COALESCE(contract.supplier_amount_minor, 0) > COALESCE((
        SELECT sum(item.amount_minor)
        FROM booking_supplier_payout_items AS item
        WHERE item.settlement_contract_id = contract.id
          AND item.state IN ('reserved', 'processing', 'paid')
      ), 0)
  ) THEN
    INSERT INTO booking_settlement_holds(
      organization_id, provider_organization_id, settlement_contract_id,
      hold_type, amount_minor, currency, source_type, source_id, reason_code
    )
    SELECT
      contract.organization_id, contract.provider_organization_id, contract.id,
      'risk',
      contract.supplier_amount_minor - COALESCE((
        SELECT sum(item.amount_minor)
        FROM booking_supplier_payout_items AS item
        WHERE item.settlement_contract_id = contract.id
          AND item.state IN ('reserved', 'processing', 'paid')
      ), 0),
      contract.currency, 'booking_payout_beneficiary', v_result.id::TEXT,
      'beneficiary_destination_change'
    FROM booking_settlement_contracts AS contract
    WHERE contract.provider_organization_id = p_organization_id
      AND contract.funded_at IS NOT NULL
      AND COALESCE(contract.supplier_amount_minor, 0) > COALESCE((
        SELECT sum(item.amount_minor)
        FROM booking_supplier_payout_items AS item
        WHERE item.settlement_contract_id = contract.id
          AND item.state IN ('reserved', 'processing', 'paid')
      ), 0)
    ON CONFLICT (settlement_contract_id, hold_type, source_type, source_id)
    DO NOTHING;
  END IF;
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine',
    COALESCE(v_previous_settlement, ''), TRUE
  );
  RETURN jsonb_build_object(
    'beneficiary_id', v_result.id, 'state', v_result.state,
    'destination_masked', v_result.destination_masked,
    'requires_independent_approval', v_result.state = 'pending_approval',
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_payout_beneficiary(
  p_beneficiary_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_beneficiary booking_payout_beneficiaries;
  v_hash TEXT;
  v_previous_booking TEXT;
  v_previous_settlement TEXT;
BEGIN
  IF p_beneficiary_id IS NULL OR p_organization_id IS NULL OR p_actor_id IS NULL
    OR p_approve IS NULL
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_DECISION_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'financial.payouts.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_beneficiary FROM booking_payout_beneficiaries
  WHERE id = p_beneficiary_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_NOT_FOUND'; END IF;
  IF v_beneficiary.proposed_by = p_actor_id
  THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_beneficiary_id, p_organization_id, p_actor_id, p_approve, btrim(p_reason)
  ), 'UTF8'), 'sha256'), 'hex');
  IF v_beneficiary.state <> 'pending_approval' THEN
    IF v_beneficiary.decision_idempotency_key = p_idempotency_key
      AND v_beneficiary.decision_request_hash = v_hash
    THEN RETURN jsonb_build_object(
      'beneficiary_id', v_beneficiary.id, 'state', v_beneficiary.state,
      'idempotency_replay', TRUE
    ); END IF;
    RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_DECIDED';
  END IF;

  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  v_previous_settlement := current_setting(
    'microfams.booking_settlement_engine', TRUE
  );
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);
  IF p_approve THEN
    UPDATE booking_payout_beneficiaries
    SET state = 'retired', updated_at = NOW()
    WHERE id = v_beneficiary.supersedes_beneficiary_id AND state = 'verified';
  END IF;
  UPDATE booking_payout_beneficiaries SET
    state = CASE WHEN p_approve THEN 'verified' ELSE 'rejected' END,
    approved_by = p_actor_id, approval_reason = btrim(p_reason),
    approved_at = NOW(), decision_idempotency_key = p_idempotency_key,
    decision_request_hash = v_hash, updated_at = NOW()
  WHERE id = v_beneficiary.id RETURNING * INTO v_beneficiary;
  UPDATE booking_settlement_holds
  SET state = 'released', released_at = NOW()
  WHERE hold_type = 'risk' AND source_type = 'booking_payout_beneficiary'
    AND source_id = v_beneficiary.id::TEXT AND state = 'active';
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine',
    COALESCE(v_previous_settlement, ''), TRUE
  );
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    p_organization_id, p_actor_id,
    CASE WHEN p_approve
      THEN 'booking.payout_beneficiary.approved'
      ELSE 'booking.payout_beneficiary.rejected' END,
    'booking_payout_beneficiary', v_beneficiary.id::TEXT,
    jsonb_build_object(
      'state', v_beneficiary.state,
      'destination_masked', v_beneficiary.destination_masked,
      'reason', btrim(p_reason)
    )
  );
  RETURN jsonb_build_object(
    'beneficiary_id', v_beneficiary.id, 'state', v_beneficiary.state,
    'destination_masked', v_beneficiary.destination_masked,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION create_booking_supplier_payout(
  p_settlement_release_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_beneficiary_id UUID,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_release booking_settlement_releases;
  v_beneficiary booking_payout_beneficiaries;
  v_existing booking_supplier_payout_items;
  v_payout payouts;
  v_item booking_supplier_payout_items;
  v_hash TEXT;
  v_previous_payout TEXT;
  v_previous_booking TEXT;
BEGIN
  IF p_settlement_release_id IS NULL OR p_organization_id IS NULL
    OR p_actor_id IS NULL OR p_beneficiary_id IS NULL OR p_correlation_id IS NULL
    OR p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic', 'sandbox', 'live')
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_INVALID'; END IF;
  IF NOT (
    has_booking_permission(
      p_organization_id, p_actor_id, 'booking.settlements.release'
    )
    AND has_booking_permission(
      p_organization_id, p_actor_id, 'financial.payouts.create'
    )
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_release FROM booking_settlement_releases
  WHERE id = p_settlement_release_id
    AND provider_organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_release.supplier_amount_minor <= 0
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_RELEASE_NOT_FOUND'; END IF;
  IF EXISTS (
    SELECT 1 FROM booking_settlement_holds
    WHERE settlement_contract_id = v_release.settlement_contract_id
      AND state = 'active'
  ) THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_HOLD_ACTIVE'; END IF;
  SELECT * INTO v_beneficiary FROM booking_payout_beneficiaries
  WHERE id = p_beneficiary_id AND organization_id = p_organization_id
    AND provider_name = p_provider_name
    AND provider_environment = p_provider_environment
    AND state = 'verified';
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_PAYOUT_BENEFICIARY_NOT_VERIFIED'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_settlement_release_id, p_organization_id, p_actor_id, p_beneficiary_id,
    p_provider_name, p_provider_environment, v_release.supplier_amount_minor,
    v_release.currency
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_supplier_payout_items
  WHERE organization_id = p_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'payout_id', v_existing.payout_id, 'item_id', v_existing.id,
      'state', v_existing.state, 'idempotency_replay', TRUE
    );
  END IF;
  IF EXISTS (
    SELECT 1 FROM booking_supplier_payout_items
    WHERE settlement_release_id = p_settlement_release_id
  ) THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_ALREADY_CREATED'; END IF;

  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  INSERT INTO payouts(
    organization_id, withdrawal_request_id, reservation_id,
    internal_reference, idempotency_key, request_hash,
    provider_name, provider_environment, currency, amount_minor,
    fee_amount_minor, beneficiary_fingerprint, beneficiary_masked,
    state, correlation_id, actor_id, source_type, source_id,
    booking_settlement_release_id, booking_payout_beneficiary_id
  ) VALUES (
    p_organization_id, NULL, NULL,
    'BSP-' || replace(p_settlement_release_id::TEXT, '-', ''),
    p_idempotency_key, v_hash, p_provider_name, p_provider_environment,
    v_release.currency, v_release.supplier_amount_minor, 0,
    v_beneficiary.destination_fingerprint, v_beneficiary.destination_masked,
    'reserved', p_correlation_id, p_actor_id, 'booking_settlement',
    p_settlement_release_id, p_settlement_release_id, p_beneficiary_id
  ) RETURNING * INTO v_payout;
  INSERT INTO booking_supplier_payout_items(
    organization_id, customer_organization_id, settlement_contract_id,
    settlement_release_id, payout_id, beneficiary_id, amount_minor, currency,
    destination_fingerprint, destination_masked, provider_name,
    provider_environment, idempotency_key, request_hash, correlation_id,
    created_by
  ) VALUES (
    p_organization_id, v_release.organization_id,
    v_release.settlement_contract_id, v_release.id, v_payout.id,
    v_beneficiary.id, v_release.supplier_amount_minor, v_release.currency,
    v_beneficiary.destination_fingerprint, v_beneficiary.destination_masked,
    p_provider_name, p_provider_environment, p_idempotency_key, v_hash,
    p_correlation_id, p_actor_id
  ) RETURNING * INTO v_item;
  PERFORM set_config(
    'microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  RETURN jsonb_build_object(
    'payout_id', v_payout.id, 'item_id', v_item.id,
    'internal_reference', v_payout.internal_reference,
    'amount_minor', v_payout.amount_minor, 'currency', v_payout.currency,
    'state', v_payout.state, 'destination_masked', v_payout.beneficiary_masked,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION succeed_booking_supplier_payout(
  p_payout_id UUID,
  p_internal_reference TEXT,
  p_provider_reference TEXT,
  p_amount_minor BIGINT,
  p_currency TEXT,
  p_beneficiary_fingerprint TEXT,
  p_organization_id UUID,
  p_provider_name TEXT,
  p_provider_environment TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payout payouts;
  v_item booking_supplier_payout_items;
  v_release booking_settlement_releases;
  v_due_to_provider UUID;
  v_customer_clearing UUID;
  v_provider_due_from UUID;
  v_external_bank UUID;
  v_customer_journal UUID;
  v_provider_journal UUID;
  v_previous_payout TEXT;
  v_previous_booking TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts
  WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'booking_settlement'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND'; END IF;
  IF p_internal_reference <> v_payout.internal_reference
    OR p_provider_reference IS NULL
    OR length(p_provider_reference) NOT BETWEEN 1 AND 160
    OR p_amount_minor <> v_payout.amount_minor
    OR upper(p_currency) <> v_payout.currency
    OR p_beneficiary_fingerprint <> v_payout.beneficiary_fingerprint
    OR p_organization_id <> v_payout.organization_id
    OR p_provider_name <> v_payout.provider_name
    OR p_provider_environment <> v_payout.provider_environment
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH'; END IF;
  IF v_payout.provider_reference IS NOT NULL
    AND v_payout.provider_reference <> p_provider_reference
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH'; END IF;
  IF v_payout.state = 'succeeded' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'succeeded')
  THEN RAISE EXCEPTION 'Payout success transition is not allowed'; END IF;
  SELECT * INTO v_item FROM booking_supplier_payout_items
  WHERE payout_id = v_payout.id FOR UPDATE;
  SELECT * INTO v_release FROM booking_settlement_releases
  WHERE id = v_item.settlement_release_id;

  v_due_to_provider := ensure_booking_settlement_account(
    v_item.customer_organization_id, v_item.organization_id, v_payout.actor_id,
    'interorganization_settlement_due_to', v_item.currency
  );
  v_customer_clearing := ensure_booking_settlement_account(
    v_item.customer_organization_id, NULL, v_payout.actor_id,
    'booking_payout_provider_clearing', v_item.currency
  );
  v_customer_journal := post_booking_settlement_journal(
    v_item.customer_organization_id, v_payout.actor_id, v_item.currency,
    'booking.supplier_payout.success', v_payout.id::TEXT,
    'booking.payout.customer:' || v_payout.id::TEXT, v_item.correlation_id,
    'Pay approved booking supplier beneficiary',
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_due_to_provider, 'line_number', 1, 'side', 'debit',
        'amount_minor', v_item.amount_minor, 'memo', 'Settle supplier proceeds due'
      ),
      jsonb_build_object(
        'account_id', v_customer_clearing, 'line_number', 2, 'side', 'credit',
        'amount_minor', v_item.amount_minor, 'memo', 'External payout provider clearing'
      )
    )
  );
  v_provider_due_from := ensure_booking_settlement_account(
    v_item.organization_id, v_item.customer_organization_id, v_payout.actor_id,
    'interorganization_settlement_due_from', v_item.currency
  );
  v_external_bank := ensure_booking_settlement_account(
    v_item.organization_id, NULL, v_payout.actor_id,
    'supplier_external_bank_asset', v_item.currency
  );
  v_provider_journal := post_booking_settlement_journal(
    v_item.organization_id, v_payout.actor_id, v_item.currency,
    'booking.supplier_payout.receipt', v_payout.id::TEXT,
    'booking.payout.provider:' || v_payout.id::TEXT, v_item.correlation_id,
    'Recognize delivery to approved supplier beneficiary',
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_external_bank, 'line_number', 1, 'side', 'debit',
        'amount_minor', v_item.amount_minor, 'memo', 'Approved external beneficiary'
      ),
      jsonb_build_object(
        'account_id', v_provider_due_from, 'line_number', 2, 'side', 'credit',
        'amount_minor', v_item.amount_minor, 'memo', 'Settle customer organization receivable'
      )
    )
  );

  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  UPDATE payouts SET
    state = 'succeeded', provider_reference = p_provider_reference,
    success_journal_entry_id = v_customer_journal,
    terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_payout.id RETURNING * INTO v_payout;
  UPDATE booking_supplier_payout_items SET
    state = 'paid', customer_journal_entry_id = v_customer_journal,
    provider_journal_entry_id = v_provider_journal,
    terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_item.id;
  PERFORM set_config(
    'microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION fail_booking_supplier_payout(
  p_payout_id UUID,
  p_failure_code TEXT,
  p_failure_reason TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payout payouts;
  v_item booking_supplier_payout_items;
  v_previous_payout TEXT;
  v_previous_booking TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'booking_settlement'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND'; END IF;
  IF v_payout.state IN ('failed', 'cancelled') THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'failed')
  THEN RAISE EXCEPTION 'Payout failure transition is not allowed'; END IF;
  SELECT * INTO v_item FROM booking_supplier_payout_items
  WHERE payout_id = v_payout.id FOR UPDATE;
  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  UPDATE payouts SET
    state = 'failed', failure_code = left(p_failure_code, 80),
    failure_reason = left(p_failure_reason, 500),
    terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_payout.id RETURNING * INTO v_payout;
  UPDATE booking_supplier_payout_items SET
    state = 'restored', terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_item.id;
  PERFORM set_config(
    'microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_booking_supplier_payout(
  p_payout_id UUID,
  p_organization_id UUID,
  p_actor_id UUID,
  p_reason TEXT,
  p_idempotency_key TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payout payouts;
  v_item booking_supplier_payout_items;
  v_hash TEXT;
  v_previous_payout TEXT;
  v_previous_booking TEXT;
BEGIN
  IF p_payout_id IS NULL OR p_organization_id IS NULL OR p_actor_id IS NULL
    OR length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 500
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_INVALID'; END IF;
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'financial.payouts.create'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  SELECT * INTO v_payout FROM payouts
  WHERE id = p_payout_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'booking_settlement'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',
    p_payout_id, p_organization_id, p_actor_id, btrim(p_reason),
    p_idempotency_key
  ), 'UTF8'), 'sha256'), 'hex');
  IF v_payout.state = 'cancelled' THEN
    IF v_payout.failure_code = 'operator_cancelled:' || left(v_hash, 32)
      AND v_payout.failure_reason = left(btrim(p_reason), 500)
    THEN RETURN v_payout; END IF;
    RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT';
  END IF;
  IF v_payout.state <> 'reserved'
  THEN RAISE EXCEPTION 'BOOKING_SUPPLIER_PAYOUT_CANCELLATION_NOT_ALLOWED'; END IF;
  SELECT * INTO v_item FROM booking_supplier_payout_items
  WHERE payout_id = v_payout.id FOR UPDATE;
  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_booking := current_setting('microfams.booking_payout_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_payout_engine', 'on', TRUE);
  UPDATE payouts SET
    state = 'cancelled',
    request_hash = COALESCE(request_hash, v_hash),
    failure_code = 'operator_cancelled:' || left(v_hash, 32),
    failure_reason = left(btrim(p_reason), 500),
    terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_payout.id RETURNING * INTO v_payout;
  UPDATE booking_supplier_payout_items SET
    state = 'restored', terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_item.id;
  PERFORM set_config(
    'microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_payout_engine', COALESCE(v_previous_booking, ''), TRUE
  );
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    p_organization_id, p_actor_id, 'booking.supplier_payout.cancelled',
    'payout', v_payout.id::TEXT,
    jsonb_build_object('reason', btrim(p_reason))
  );
  RETURN v_payout;
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_payout_beneficiaries(
  p_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'booking.settlements.release'
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', beneficiary.id,
      'beneficiary_user_id', beneficiary.beneficiary_user_id,
      'destination_masked', beneficiary.destination_masked,
      'account_name_masked', beneficiary.account_name_masked,
      'provider_name', beneficiary.provider_name,
      'provider_environment', beneficiary.provider_environment,
      'state', beneficiary.state,
      'supersedes_beneficiary_id', beneficiary.supersedes_beneficiary_id,
      'change_rule_snapshot', beneficiary.change_rule_snapshot,
      'created_at', beneficiary.created_at,
      'approved_at', beneficiary.approved_at
    ) ORDER BY beneficiary.created_at DESC, beneficiary.id)
    FROM booking_payout_beneficiaries AS beneficiary
    WHERE beneficiary.organization_id = p_organization_id
  ), '[]'::JSONB);
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'financial.payouts.create',
    'financial.payouts.approve',
    'financial.payouts.rules.propose',
    'financial.payouts.rules.approve'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_payout_destination_change_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_payout_beneficiaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_supplier_payout_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_payout_destination_change_rules,
  booking_payout_beneficiaries, booking_supplier_payout_items
  FROM anon, authenticated;
GRANT SELECT ON booking_payout_destination_change_rules,
  booking_payout_beneficiaries, booking_supplier_payout_items TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_payout_destination_change_rules,
  booking_payout_beneficiaries, booking_supplier_payout_items FROM service_role;

REVOKE ALL ON FUNCTION protect_booking_payout_records()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION populate_payout_source_identity()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION provision_default_booking_payout_change_rule()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION sync_booking_supplier_payout_item_state()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION propose_booking_payout_change_rule(
  UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_booking_payout_change_rule(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION register_booking_payout_beneficiary(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_booking_payout_beneficiary(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION create_booking_supplier_payout(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION succeed_booking_supplier_payout(
  UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fail_booking_supplier_payout(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cancel_booking_supplier_payout(
  UUID, UUID, UUID, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION read_booking_payout_beneficiaries(UUID, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION register_booking_payout_beneficiary(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION propose_booking_payout_change_rule(
  UUID, UUID, INTEGER, INTEGER, TIMESTAMPTZ, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_payout_change_rule(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_payout_beneficiary(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION create_booking_supplier_payout(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION succeed_booking_supplier_payout(
  UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION fail_booking_supplier_payout(UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION cancel_booking_supplier_payout(
  UUID, UUID, UUID, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION read_booking_payout_beneficiaries(UUID, UUID)
  TO service_role;
