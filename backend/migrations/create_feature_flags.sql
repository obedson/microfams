-- Server-owned, tenant-aware feature controls for Micro Fams V1.
-- Client applications never evaluate these tables as an authorization control.

CREATE TABLE IF NOT EXISTS feature_flags (
  key TEXT PRIMARY KEY,
  domain TEXT NOT NULL,
  description TEXT NOT NULL,
  default_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  failure_mode TEXT NOT NULL CHECK (failure_mode IN ('open', 'closed')),
  risk TEXT NOT NULL CHECK (risk IN ('standard', 'provider', 'regulated')),
  emergency_disabled BOOLEAN NOT NULL DEFAULT FALSE,
  emergency_reason TEXT,
  emergency_changed_at TIMESTAMPTZ,
  emergency_changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS feature_flag_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key TEXT NOT NULL REFERENCES feature_flags(key) ON DELETE CASCADE,
  scope_type TEXT NOT NULL CHECK (scope_type IN ('global', 'jurisdiction', 'tenant', 'actor')),
  scope_id TEXT,
  environment TEXT NOT NULL CHECK (environment IN ('all', 'development', 'test', 'staging', 'production')),
  enabled BOOLEAN NOT NULL,
  config JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(config) = 'object'),
  reason TEXT NOT NULL,
  effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  effective_until TIMESTAMPTZ,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT feature_override_scope_id CHECK (
    (scope_type = 'global' AND scope_id IS NULL)
    OR (scope_type <> 'global' AND scope_id IS NOT NULL)
  ),
  CONSTRAINT feature_override_window CHECK (effective_until IS NULL OR effective_until > effective_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_feature_flag_override_scope
  ON feature_flag_overrides(feature_key, scope_type, COALESCE(scope_id, ''), environment, effective_from);
CREATE INDEX IF NOT EXISTS idx_feature_flag_override_lookup
  ON feature_flag_overrides(feature_key, environment, scope_type, scope_id);
CREATE INDEX IF NOT EXISTS idx_feature_flag_override_window
  ON feature_flag_overrides(effective_from, effective_until);

CREATE TABLE IF NOT EXISTS feature_flag_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  before_value JSONB,
  after_value JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION audit_feature_flag_change() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO feature_flag_audit_log(feature_key, action, actor_id, before_value, after_value)
  VALUES (
    COALESCE(
      to_jsonb(NEW)->>'feature_key',
      to_jsonb(NEW)->>'key',
      to_jsonb(OLD)->>'feature_key',
      to_jsonb(OLD)->>'key'
    ),
    TG_OP,
    COALESCE(
      (to_jsonb(NEW)->>'created_by')::UUID,
      (to_jsonb(NEW)->>'emergency_changed_by')::UUID,
      (to_jsonb(OLD)->>'created_by')::UUID,
      (to_jsonb(OLD)->>'emergency_changed_by')::UUID
    ),
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
  );
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS feature_flags_audit ON feature_flags;
CREATE TRIGGER feature_flags_audit
  AFTER INSERT OR UPDATE OR DELETE ON feature_flags
  FOR EACH ROW EXECUTE FUNCTION audit_feature_flag_change();

DROP TRIGGER IF EXISTS feature_flag_overrides_audit ON feature_flag_overrides;
CREATE TRIGGER feature_flag_overrides_audit
  AFTER INSERT OR UPDATE OR DELETE ON feature_flag_overrides
  FOR EACH ROW EXECUTE FUNCTION audit_feature_flag_change();

ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flag_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flag_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON feature_flags, feature_flag_overrides, feature_flag_audit_log FROM anon, authenticated;

INSERT INTO feature_flags(key, domain, description, default_enabled, failure_mode, risk) VALUES
  ('financial.payments.accept_new', 'payments', 'Accept new customer payment attempts.', FALSE, 'closed', 'regulated'),
  ('financial.payments.service_existing', 'payments', 'Service existing payments.', TRUE, 'open', 'regulated'),
  ('financial.payouts.create', 'payments', 'Create new beneficiary payouts.', FALSE, 'closed', 'regulated'),
  ('financial.payouts.service_existing', 'payments', 'Service submitted payouts.', TRUE, 'open', 'regulated'),
  ('financial.wallets.transact', 'wallets', 'Create wallet transactions.', FALSE, 'closed', 'regulated'),
  ('financial.wallets.read', 'wallets', 'Read wallet balances and statements.', TRUE, 'open', 'regulated'),
  ('financial.escrow.create', 'escrow', 'Create and fund escrow contracts.', FALSE, 'closed', 'regulated'),
  ('financial.escrow.service_existing', 'escrow', 'Service existing escrow obligations.', TRUE, 'open', 'regulated'),
  ('financial.savings.enrol', 'savings', 'Open savings enrolments.', FALSE, 'closed', 'regulated'),
  ('financial.savings.service_existing', 'savings', 'Service existing savings.', TRUE, 'open', 'regulated'),
  ('financial.investments.subscribe', 'investments', 'Accept investment subscriptions.', FALSE, 'closed', 'regulated'),
  ('financial.investments.service_existing', 'investments', 'Service existing investments.', TRUE, 'open', 'regulated'),
  ('financial.loans.originate', 'loans', 'Originate loans.', FALSE, 'closed', 'regulated'),
  ('financial.loans.service_existing', 'loans', 'Service existing loans.', TRUE, 'open', 'regulated'),
  ('financial.dividends.declare', 'dividends', 'Declare distributions.', FALSE, 'closed', 'regulated'),
  ('financial.dividends.service_existing', 'dividends', 'Service approved distributions.', TRUE, 'open', 'regulated'),
  ('financial.accounting.post', 'accounting', 'Post general-ledger events.', FALSE, 'closed', 'regulated'),
  ('financial.accounting.read', 'accounting', 'Read accounting records.', TRUE, 'open', 'regulated'),
  ('integration.paystack.live', 'payments', 'Use Paystack live mode.', FALSE, 'closed', 'provider'),
  ('integration.interswitch.live', 'payments', 'Use Interswitch live mode.', FALSE, 'closed', 'provider'),
  ('integration.identity_verification', 'identity', 'Use identity verification provider.', FALSE, 'closed', 'provider'),
  ('integration.sms', 'communications', 'Use SMS provider.', FALSE, 'closed', 'provider'),
  ('integration.weather', 'intelligence', 'Use weather provider.', FALSE, 'closed', 'provider'),
  ('integration.satellite', 'intelligence', 'Use satellite provider.', FALSE, 'closed', 'provider'),
  ('integration.ai_assistant', 'intelligence', 'Use AI provider.', FALSE, 'closed', 'provider'),
  ('institutional.government_dashboard', 'institutional', 'Enable government dashboards.', FALSE, 'closed', 'standard'),
  ('institutional.ngo_dashboard', 'institutional', 'Enable NGO dashboards.', FALSE, 'closed', 'standard'),
  ('farm_erp.operations', 'farm_erp', 'Enable farm ERP operations.', FALSE, 'closed', 'standard')
ON CONFLICT (key) DO UPDATE SET
  domain = EXCLUDED.domain,
  description = EXCLUDED.description,
  default_enabled = EXCLUDED.default_enabled,
  failure_mode = EXCLUDED.failure_mode,
  risk = EXCLUDED.risk,
  updated_at = NOW();
