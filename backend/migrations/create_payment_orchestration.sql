-- FC-05/FC-06 inbound payments, refunds, reversals, fees and settlement records.

CREATE TABLE IF NOT EXISTS payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  source_type TEXT NOT NULL CHECK (source_type IN ('booking', 'marketplace_order', 'wallet', 'group_membership', 'contribution')),
  source_id UUID NOT NULL,
  payer_id UUID REFERENCES users(id) ON DELETE SET NULL,
  internal_reference TEXT NOT NULL CHECK (length(internal_reference) BETWEEN 8 AND 160),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_reference TEXT,
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  state TEXT NOT NULL DEFAULT 'created' CHECK (state IN (
    'created', 'requires_action', 'processing', 'succeeded', 'failed', 'cancelled',
    'expired', 'partially_refunded', 'refunded'
  )),
  correlation_id UUID NOT NULL,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  success_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  failure_code TEXT,
  failure_reason TEXT,
  action_expires_at TIMESTAMPTZ,
  initialized_at TIMESTAMPTZ,
  terminal_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, internal_reference),
  UNIQUE (organization_id, idempotency_key)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_provider_reference
  ON payments(provider_name, provider_environment, provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_payments_recovery
  ON payments(provider_name, provider_environment, state, updated_at)
  WHERE state IN ('requires_action', 'processing');

CREATE TABLE IF NOT EXISTS payment_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL CHECK (state IN ('started', 'requires_action', 'processing', 'accepted', 'unknown', 'failed')),
  provider_reference TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  UNIQUE (payment_id, attempt_number),
  UNIQUE (payment_id, request_hash)
);

CREATE TABLE IF NOT EXISTS payment_refunds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  internal_reference TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  provider_reference TEXT,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
  state TEXT NOT NULL DEFAULT 'created' CHECK (state IN ('created', 'submitted', 'processing', 'succeeded', 'failed', 'cancelled')),
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  approval_reference TEXT,
  journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  failure_code TEXT,
  failure_reason TEXT,
  terminal_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, internal_reference),
  UNIQUE (organization_id, idempotency_key)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_refund_provider_reference
  ON payment_refunds(provider_reference) WHERE provider_reference IS NOT NULL;

CREATE TABLE IF NOT EXISTS payment_reversals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  provider_event_id TEXT,
  internal_reference TEXT NOT NULL,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
  journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
  occurred_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, internal_reference),
  UNIQUE (payment_id, provider_event_id)
);

CREATE TABLE IF NOT EXISTS settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  provider_reference TEXT NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  gross_amount_minor BIGINT NOT NULL CHECK (gross_amount_minor > 0),
  fee_amount_minor BIGINT NOT NULL DEFAULT 0 CHECK (fee_amount_minor >= 0),
  net_amount_minor BIGINT NOT NULL CHECK (net_amount_minor > 0),
  source_hash VARCHAR(64) NOT NULL CHECK (source_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL DEFAULT 'received' CHECK (state IN ('received', 'posted', 'reconciled', 'exception')),
  settled_at TIMESTAMPTZ NOT NULL,
  journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider_name, provider_environment, provider_reference),
  UNIQUE (provider_name, provider_environment, source_hash),
  CHECK (net_amount_minor + fee_amount_minor = gross_amount_minor)
);

CREATE TABLE IF NOT EXISTS payment_fees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payment_id UUID REFERENCES payments(id),
  settlement_id UUID REFERENCES settlements(id),
  fee_type TEXT NOT NULL CHECK (fee_type IN ('provider_processing', 'platform')),
  payer_type TEXT NOT NULL CHECK (payer_type IN ('organization', 'customer', 'provider')),
  beneficiary_type TEXT NOT NULL CHECK (beneficiary_type IN ('organization', 'platform', 'provider')),
  rule_version TEXT NOT NULL,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  tax_metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS settlement_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_id UUID NOT NULL REFERENCES settlements(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (settlement_id, payment_id)
);

CREATE TABLE IF NOT EXISTS payment_provider_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  provider_name TEXT NOT NULL,
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

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_provider_event_identifier
  ON payment_provider_events(provider_name, provider_environment, provider_event_id)
  WHERE provider_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION protect_payment_engine_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF current_setting('microfams.payment_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Payment records can only be changed by the payment engine';
END;
$$;

CREATE TRIGGER payments_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER payment_attempts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payment_attempts
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER payment_refunds_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payment_refunds
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER payment_reversals_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payment_reversals
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
ALTER TABLE reconciliation_items
  ADD COLUMN IF NOT EXISTS payment_id UUID REFERENCES payments(id);

CREATE TRIGGER settlements_engine_only BEFORE INSERT OR UPDATE OR DELETE ON settlements
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER settlement_items_engine_only BEFORE INSERT OR UPDATE OR DELETE ON settlement_items
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER payment_fees_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payment_fees
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();
CREATE TRIGGER payment_provider_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON payment_provider_events
  FOR EACH ROW EXECUTE FUNCTION protect_payment_engine_records();

CREATE OR REPLACE FUNCTION payment_transition_allowed(p_from TEXT, p_to TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT p_from = p_to OR CASE p_from
  WHEN 'created' THEN p_to IN ('requires_action', 'processing', 'failed', 'cancelled', 'expired')
  WHEN 'requires_action' THEN p_to IN ('processing', 'succeeded', 'failed', 'cancelled', 'expired')
  WHEN 'processing' THEN p_to IN ('succeeded', 'failed', 'cancelled', 'expired')
  WHEN 'succeeded' THEN p_to IN ('partially_refunded', 'refunded')
  WHEN 'partially_refunded' THEN p_to IN ('partially_refunded', 'refunded')
  ELSE FALSE
END $$;
