-- FC-07: effective-dated financial rules, maker-checker approvals, risk controls and immutable decisions.

CREATE TABLE financial_rule_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
  rule_code TEXT NOT NULL CHECK (rule_code ~ '^[a-z][a-z0-9_.-]{2,79}$'),
  version INTEGER NOT NULL CHECK (version > 0),
  jurisdiction CHAR(2),
  product TEXT NOT NULL,
  channel TEXT NOT NULL DEFAULT '*',
  currency CHAR(3) NOT NULL,
  minimum_kyc_tier SMALLINT NOT NULL DEFAULT 0 CHECK (minimum_kyc_tier BETWEEN 0 AND 5),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'active', 'retired', 'rejected')),
  effective_from TIMESTAMPTZ NOT NULL,
  effective_until TIMESTAMPTZ,
  regulatory_source TEXT,
  regulatory_source_effective_date DATE,
  change_reason TEXT NOT NULL,
  created_by UUID REFERENCES users(id),
  submitted_at TIMESTAMPTZ,
  approved_by UUID REFERENCES users(id),
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (effective_until IS NULL OR effective_until > effective_from),
  CHECK (jurisdiction IS NULL OR jurisdiction = upper(jurisdiction)),
  CHECK (currency = upper(currency)),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
CREATE UNIQUE INDEX uq_financial_rule_version
  ON financial_rule_versions(COALESCE(organization_id, '00000000-0000-0000-0000-000000000000'), rule_code, version);
CREATE INDEX idx_financial_rule_lookup
  ON financial_rule_versions(organization_id, product, channel, currency, jurisdiction, status, effective_from);

CREATE TABLE financial_rule_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_version_id UUID NOT NULL REFERENCES financial_rule_versions(id) ON DELETE CASCADE,
  dimension TEXT NOT NULL CHECK (dimension IN (
    'per_transaction', 'rolling_period', 'calendar_day', 'balance', 'velocity', 'beneficiary', 'aggregate'
  )),
  minimum_minor BIGINT CHECK (minimum_minor IS NULL OR minimum_minor >= 0),
  maximum_minor BIGINT CHECK (maximum_minor IS NULL OR maximum_minor > 0),
  provider_regulatory_ceiling_minor BIGINT CHECK (
    provider_regulatory_ceiling_minor IS NULL OR provider_regulatory_ceiling_minor > 0
  ),
  period_seconds INTEGER CHECK (period_seconds IS NULL OR period_seconds > 0),
  maximum_count INTEGER CHECK (maximum_count IS NULL OR maximum_count > 0),
  CHECK (minimum_minor IS NOT NULL OR maximum_minor IS NOT NULL OR maximum_count IS NOT NULL),
  CHECK (maximum_minor IS NULL OR provider_regulatory_ceiling_minor IS NULL
    OR maximum_minor <= provider_regulatory_ceiling_minor),
  UNIQUE(rule_version_id, dimension)
);

CREATE TABLE financial_approval_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL CHECK (action_type IN (
    'rule_activation', 'limit_increase', 'manual_adjustment', 'live_activation',
    'regulated_feature_override', 'reconciliation_writeoff', 'period_reopen'
  )),
  resource_type TEXT NOT NULL,
  resource_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'approved', 'rejected', 'cancelled')),
  requested_by UUID NOT NULL REFERENCES users(id),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decided_by UUID REFERENCES users(id),
  decided_at TIMESTAMPTZ,
  reason TEXT NOT NULL,
  CHECK (decided_by IS NULL OR decided_by <> requested_by)
);
CREATE UNIQUE INDEX uq_pending_financial_approval
  ON financial_approval_requests(organization_id, action_type, resource_id) WHERE state = 'pending';

CREATE TABLE financial_risk_controls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  control_type TEXT NOT NULL CHECK (control_type IN ('hold', 'freeze', 'sanctions', 'manual_review')),
  subject_type TEXT NOT NULL CHECK (subject_type IN ('organization', 'user', 'beneficiary')),
  subject_id TEXT NOT NULL,
  product TEXT NOT NULL DEFAULT '*',
  blocks_new_exposure BOOLEAN NOT NULL DEFAULT TRUE,
  reason_code TEXT NOT NULL,
  reason TEXT NOT NULL,
  effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  effective_until TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES users(id),
  released_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (effective_until IS NULL OR effective_until > effective_from)
);
CREATE INDEX idx_financial_risk_control_lookup
  ON financial_risk_controls(organization_id, subject_type, subject_id, product, effective_from);

CREATE TABLE financial_live_activations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  product TEXT NOT NULL,
  jurisdiction CHAR(2) NOT NULL,
  licensed_provider TEXT NOT NULL,
  compliance_owner_id UUID NOT NULL REFERENCES users(id),
  approval_evidence_reference TEXT NOT NULL,
  kyc_rules_reference TEXT NOT NULL,
  regulatory_source TEXT NOT NULL,
  regulatory_source_effective_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending_approval' CHECK (status IN ('pending_approval', 'active', 'suspended', 'retired')),
  requested_by UUID NOT NULL REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  effective_from TIMESTAMPTZ NOT NULL,
  effective_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (approved_by IS NULL OR approved_by <> requested_by),
  CHECK (effective_until IS NULL OR effective_until > effective_from)
);
CREATE UNIQUE INDEX uq_financial_live_activation
  ON financial_live_activations(organization_id, product, jurisdiction, effective_from);

CREATE TABLE financial_kyc_evidence (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  evidence_type TEXT NOT NULL CHECK (evidence_type IN ('bvn', 'nin')),
  provider_name TEXT NOT NULL,
  provider_reference TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('validated', 'rejected', 'expired', 'revoked')),
  validated_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  recorded_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((status = 'validated' AND validated_at IS NOT NULL) OR status <> 'validated'),
  UNIQUE(organization_id, user_id, evidence_type, provider_name, provider_reference)
);
CREATE INDEX idx_financial_kyc_active
  ON financial_kyc_evidence(organization_id, user_id, evidence_type, status, expires_at);

CREATE TABLE financial_compliance_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_id UUID NOT NULL REFERENCES users(id),
  command_type TEXT NOT NULL,
  command_id TEXT NOT NULL,
  product TEXT NOT NULL,
  channel TEXT NOT NULL,
  currency CHAR(3) NOT NULL,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  beneficiary_fingerprint VARCHAR(64),
  rule_version_id UUID REFERENCES financial_rule_versions(id),
  rule_version INTEGER,
  kyc_tier SMALLINT NOT NULL,
  approved BOOLEAN NOT NULL,
  reasons TEXT[] NOT NULL DEFAULT '{}',
  evaluated_facts JSONB NOT NULL,
  decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(organization_id, command_type, command_id)
);
CREATE INDEX idx_financial_snapshot_usage
  ON financial_compliance_snapshots(organization_id, actor_id, product, channel, decided_at)
  WHERE approved;

CREATE OR REPLACE FUNCTION has_financial_permission(p_org UUID, p_actor UUID, p_permission TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_org AND user_id = p_actor AND status = 'active'
      AND (role = 'owner' OR p_permission = ANY(permissions) OR 'financial.*' = ANY(permissions))
  );
$$;

UPDATE organization_memberships
SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'financial.rules.propose', 'financial.rules.approve',
    'financial.risk.manage', 'financial.activation.manage',
    'financial.journals.post', 'financial.refunds.create',
    'financial.payouts.submit', 'financial.reconciliation.manual',
    'financial.periods.close', 'financial.periods.reopen'
  ]) permission
)
WHERE role = 'owner';

CREATE OR REPLACE FUNCTION protect_approved_financial_policy() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.status IN ('active', 'retired') THEN
    RAISE EXCEPTION 'Approved financial policy is immutable';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IN ('active', 'retired')
    AND (to_jsonb(OLD) - 'status' - 'effective_until') IS DISTINCT FROM
        (to_jsonb(NEW) - 'status' - 'effective_until') THEN
    RAISE EXCEPTION 'Approved financial policy content is immutable';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER financial_rule_version_immutable
  BEFORE UPDATE OR DELETE ON financial_rule_versions
  FOR EACH ROW EXECUTE FUNCTION protect_approved_financial_policy();

CREATE OR REPLACE FUNCTION submit_financial_rule(p_rule_id UUID, p_actor UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rule financial_rule_versions; v_request UUID;
BEGIN
  SELECT * INTO v_rule FROM financial_rule_versions WHERE id = p_rule_id FOR UPDATE;
  IF v_rule.id IS NULL OR v_rule.status <> 'draft' THEN RAISE EXCEPTION 'Draft rule not found'; END IF;
  IF v_rule.organization_id IS NULL THEN RAISE EXCEPTION 'Platform rules require the controlled release process'; END IF;
  IF NOT has_financial_permission(v_rule.organization_id, p_actor, 'financial.rules.propose') THEN
    RAISE EXCEPTION 'Missing financial.rules.propose permission';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM financial_rule_limits WHERE rule_version_id = p_rule_id) THEN
    RAISE EXCEPTION 'A rule requires at least one limit';
  END IF;
  UPDATE financial_rule_versions SET status = 'pending_approval', submitted_at = NOW() WHERE id = p_rule_id;
  INSERT INTO financial_approval_requests(
    organization_id, action_type, resource_type, resource_id, requested_by, reason
  ) VALUES (
    v_rule.organization_id, 'rule_activation', 'financial_rule_version', p_rule_id, p_actor, v_rule.change_reason
  ) RETURNING id INTO v_request;
  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION decide_financial_rule(p_request_id UUID, p_actor UUID, p_approve BOOLEAN, p_reason TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_request financial_approval_requests; v_rule financial_rule_versions;
BEGIN
  SELECT * INTO v_request FROM financial_approval_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL OR v_request.state <> 'pending' OR v_request.action_type <> 'rule_activation' THEN
    RAISE EXCEPTION 'Pending rule approval not found';
  END IF;
  IF v_request.requested_by = p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own request'; END IF;
  IF NOT has_financial_permission(v_request.organization_id, p_actor, 'financial.rules.approve') THEN
    RAISE EXCEPTION 'Missing financial.rules.approve permission';
  END IF;
  SELECT * INTO v_rule FROM financial_rule_versions WHERE id = v_request.resource_id FOR UPDATE;
  IF p_approve AND EXISTS (
    SELECT 1 FROM financial_rule_limits
    WHERE rule_version_id = v_rule.id AND maximum_minor > provider_regulatory_ceiling_minor
  ) THEN RAISE EXCEPTION 'Configured limit exceeds provider or regulatory ceiling'; END IF;
  UPDATE financial_approval_requests SET
    state = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    decided_by = p_actor, decided_at = NOW(), reason = p_reason
  WHERE id = p_request_id;
  UPDATE financial_rule_versions SET
    status = CASE WHEN p_approve THEN 'active' ELSE 'rejected' END,
    approved_by = CASE WHEN p_approve THEN p_actor ELSE NULL END,
    approved_at = CASE WHEN p_approve THEN NOW() ELSE NULL END
  WHERE id = v_rule.id;
  RETURN v_rule.id;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_financial_command(
  p_organization_id UUID, p_actor_id UUID, p_command_type TEXT, p_command_id TEXT,
  p_product TEXT, p_channel TEXT, p_currency TEXT, p_amount_minor BIGINT,
  p_jurisdiction TEXT DEFAULT 'NG', p_beneficiary_fingerprint TEXT DEFAULT NULL,
  p_balance_minor BIGINT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing financial_compliance_snapshots;
  v_rule financial_rule_versions;
  v_limit financial_rule_limits;
  v_kyc_tier SMALLINT := 0;
  v_reasons TEXT[] := '{}';
  v_usage BIGINT;
  v_count BIGINT;
  v_snapshot UUID;
  v_now TIMESTAMPTZ := NOW();
BEGIN
  IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization_id::TEXT || ':' || p_command_type || ':' || p_command_id, 0));
  SELECT * INTO v_existing FROM financial_compliance_snapshots
    WHERE organization_id = p_organization_id AND command_type = p_command_type AND command_id = p_command_id;
  IF v_existing.id IS NOT NULL THEN
    IF (v_existing.actor_id, v_existing.product, v_existing.channel, v_existing.currency,
        v_existing.amount_minor, v_existing.beneficiary_fingerprint)
      IS DISTINCT FROM
       (p_actor_id, p_product, p_channel, upper(p_currency), p_amount_minor, p_beneficiary_fingerprint) THEN
      RAISE EXCEPTION 'Financial command idempotency key reused with different facts';
    END IF;

    RETURN jsonb_build_object('snapshot_id', v_existing.id, 'approved', v_existing.approved,
      'reasons', v_existing.reasons, 'rule_version_id', v_existing.rule_version_id,
      'rule_version', v_existing.rule_version);
  END IF;

  SELECT LEAST(count(DISTINCT evidence_type), 2)::SMALLINT INTO v_kyc_tier
  FROM financial_kyc_evidence
  WHERE organization_id = p_organization_id AND user_id = p_actor_id
    AND status = 'validated' AND validated_at <= v_now
    AND (expires_at IS NULL OR expires_at > v_now);
  v_kyc_tier := COALESCE(v_kyc_tier, 0);
  IF EXISTS (
    SELECT 1 FROM financial_risk_controls
    WHERE organization_id = p_organization_id AND blocks_new_exposure
      AND released_at IS NULL AND effective_from <= v_now
      AND (effective_until IS NULL OR effective_until > v_now)
      AND (product = '*' OR product = p_product)
      AND ((subject_type = 'organization' AND subject_id = p_organization_id::TEXT)
        OR (subject_type = 'user' AND subject_id = p_actor_id::TEXT)
        OR (subject_type = 'beneficiary' AND subject_id = COALESCE(p_beneficiary_fingerprint, '')))
  ) THEN v_reasons := array_append(v_reasons, 'risk_control_active'); END IF;

  SELECT * INTO v_rule FROM financial_rule_versions
  WHERE status = 'active' AND effective_from <= v_now AND (effective_until IS NULL OR effective_until > v_now)
    AND (organization_id = p_organization_id OR organization_id IS NULL)
    AND (jurisdiction = upper(p_jurisdiction) OR jurisdiction IS NULL)
    AND (product = p_product OR product = '*') AND (channel = p_channel OR channel = '*')
    AND currency = upper(p_currency) AND minimum_kyc_tier <= v_kyc_tier
  ORDER BY (organization_id IS NOT NULL) DESC, (product <> '*') DESC, (channel <> '*') DESC,
    (jurisdiction IS NOT NULL) DESC, version DESC LIMIT 1;

  IF v_rule.id IS NULL THEN v_reasons := array_append(v_reasons, 'no_applicable_rule');
  ELSE
    FOR v_limit IN SELECT * FROM financial_rule_limits WHERE rule_version_id = v_rule.id LOOP
      IF v_limit.minimum_minor IS NOT NULL AND p_amount_minor < v_limit.minimum_minor THEN
        v_reasons := array_append(v_reasons, 'minimum_amount');
      END IF;
      IF v_limit.dimension = 'per_transaction' AND v_limit.maximum_minor IS NOT NULL
        AND p_amount_minor > v_limit.maximum_minor THEN
        v_reasons := array_append(v_reasons, 'per_transaction_maximum');
      ELSIF v_limit.dimension = 'balance' AND v_limit.maximum_minor IS NOT NULL
        AND COALESCE(p_balance_minor, 0) + p_amount_minor > v_limit.maximum_minor THEN
        v_reasons := array_append(v_reasons, 'balance_maximum');
      ELSIF v_limit.dimension IN ('rolling_period', 'calendar_day', 'aggregate', 'beneficiary', 'velocity') THEN
        SELECT COALESCE(sum(amount_minor), 0), count(*) INTO v_usage, v_count
        FROM financial_compliance_snapshots
        WHERE organization_id = p_organization_id AND actor_id = p_actor_id AND approved
          AND product = p_product AND channel = p_channel
          AND (v_limit.dimension <> 'beneficiary' OR beneficiary_fingerprint = p_beneficiary_fingerprint)
          AND (v_limit.dimension = 'aggregate'
            OR (v_limit.dimension = 'calendar_day' AND decided_at >= date_trunc('day', v_now))
            OR (v_limit.dimension <> 'calendar_day' AND decided_at >= v_now - make_interval(secs => COALESCE(v_limit.period_seconds, 86400))));
        IF v_limit.maximum_minor IS NOT NULL AND v_usage + p_amount_minor > v_limit.maximum_minor THEN
          v_reasons := array_append(v_reasons, v_limit.dimension || '_maximum');
        END IF;
        IF v_limit.maximum_count IS NOT NULL AND v_count + 1 > v_limit.maximum_count THEN
          v_reasons := array_append(v_reasons, v_limit.dimension || '_maximum_count');
        END IF;
      END IF;
    END LOOP;
  END IF;

  INSERT INTO financial_compliance_snapshots(
    organization_id, actor_id, command_type, command_id, product, channel, currency,
    amount_minor, beneficiary_fingerprint, rule_version_id, rule_version, kyc_tier,
    approved, reasons, evaluated_facts
  ) VALUES (
    p_organization_id, p_actor_id, p_command_type, p_command_id, p_product, p_channel, upper(p_currency),
    p_amount_minor, p_beneficiary_fingerprint, v_rule.id, v_rule.version, v_kyc_tier,
    cardinality(v_reasons) = 0, v_reasons,
    jsonb_build_object('jurisdiction', upper(p_jurisdiction), 'balance_minor', p_balance_minor)
  ) RETURNING id INTO v_snapshot;
  RETURN jsonb_build_object('snapshot_id', v_snapshot, 'approved', cardinality(v_reasons) = 0,
    'reasons', v_reasons, 'rule_version_id', v_rule.id, 'rule_version', v_rule.version);
END;
$$;

CREATE OR REPLACE FUNCTION place_financial_risk_control(
  p_organization_id UUID, p_actor UUID, p_control_type TEXT, p_subject_type TEXT,
  p_subject_id TEXT, p_product TEXT, p_reason_code TEXT, p_reason TEXT,
  p_effective_until TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT has_financial_permission(p_organization_id, p_actor, 'financial.risk.manage') THEN
    RAISE EXCEPTION 'Missing financial.risk.manage permission';
  END IF;
  INSERT INTO financial_risk_controls(
    organization_id, control_type, subject_type, subject_id, product,
    reason_code, reason, effective_until, created_by
  ) VALUES (
    p_organization_id, p_control_type, p_subject_type, p_subject_id, COALESCE(p_product, '*'),
    p_reason_code, p_reason, p_effective_until, p_actor
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION release_financial_risk_control(p_control_id UUID, p_actor UUID, p_reason TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_control financial_risk_controls;
BEGIN
  SELECT * INTO v_control FROM financial_risk_controls WHERE id = p_control_id FOR UPDATE;
  IF v_control.id IS NULL OR v_control.released_at IS NOT NULL THEN
    RAISE EXCEPTION 'Active financial risk control not found';
  END IF;
  IF NOT has_financial_permission(v_control.organization_id, p_actor, 'financial.risk.manage') THEN
    RAISE EXCEPTION 'Missing financial.risk.manage permission';
  END IF;
  UPDATE financial_risk_controls SET released_at = NOW(), released_by = p_actor,
    reason = reason || E'\nRelease: ' || p_reason WHERE id = p_control_id;
  RETURN p_control_id;
END;
$$;

CREATE OR REPLACE FUNCTION request_financial_live_activation(
  p_organization_id UUID, p_actor UUID, p_product TEXT, p_jurisdiction TEXT,
  p_licensed_provider TEXT, p_compliance_owner UUID, p_approval_evidence TEXT,
  p_kyc_rules TEXT, p_regulatory_source TEXT, p_regulatory_effective_date DATE,
  p_effective_from TIMESTAMPTZ
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_activation UUID;
BEGIN
  IF NOT has_financial_permission(p_organization_id, p_actor, 'financial.activation.manage') THEN
    RAISE EXCEPTION 'Missing financial.activation.manage permission';
  END IF;
  INSERT INTO financial_live_activations(
    organization_id, product, jurisdiction, licensed_provider, compliance_owner_id,
    approval_evidence_reference, kyc_rules_reference, regulatory_source,
    regulatory_source_effective_date, requested_by, effective_from
  ) VALUES (
    p_organization_id, p_product, upper(p_jurisdiction), p_licensed_provider, p_compliance_owner,
    p_approval_evidence, p_kyc_rules, p_regulatory_source,
    p_regulatory_effective_date, p_actor, p_effective_from
  ) RETURNING id INTO v_activation;
  INSERT INTO financial_approval_requests(
    organization_id, action_type, resource_type, resource_id, requested_by, reason
  ) VALUES (
    p_organization_id, 'live_activation', 'financial_live_activation',
    v_activation, p_actor, 'Activate regulated financial product'
  );
  RETURN v_activation;
END;
$$;

CREATE OR REPLACE FUNCTION decide_financial_live_activation(
  p_activation_id UUID, p_actor UUID, p_approve BOOLEAN, p_reason TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_activation financial_live_activations; v_request financial_approval_requests;
BEGIN
  SELECT * INTO v_activation FROM financial_live_activations WHERE id = p_activation_id FOR UPDATE;
  SELECT * INTO v_request FROM financial_approval_requests
    WHERE resource_id = p_activation_id AND action_type = 'live_activation' AND state = 'pending' FOR UPDATE;
  IF v_activation.id IS NULL OR v_request.id IS NULL THEN
    RAISE EXCEPTION 'Pending live activation not found';
  END IF;
  IF v_activation.requested_by = p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own request'; END IF;
  IF NOT has_financial_permission(v_activation.organization_id, p_actor, 'financial.activation.manage') THEN
    RAISE EXCEPTION 'Missing financial.activation.manage permission';
  END IF;
  UPDATE financial_live_activations SET
    status = CASE WHEN p_approve THEN 'active' ELSE 'retired' END,
    approved_by = CASE WHEN p_approve THEN p_actor ELSE NULL END
  WHERE id = p_activation_id;
  UPDATE financial_approval_requests SET
    state = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    decided_by = p_actor, decided_at = NOW(), reason = p_reason
  WHERE id = v_request.id;
  RETURN p_activation_id;
END;
$$;

-- Configurable platform test defaults. They are product test policy, never represented as legal limits.

INSERT INTO financial_rule_versions(
  rule_code, version, jurisdiction, product, channel, currency, minimum_kyc_tier,
  status, effective_from, change_reason, approved_at
)
SELECT defaults.rule_code, 1, 'NG', defaults.product, defaults.channel, 'NGN', 0, 'active',
  TIMESTAMPTZ '2020-01-01 00:00:00+00', 'FC-07 configurable V1 test default', NOW()
FROM (VALUES
  ('test.wallet.p2p', 'wallet', 'p2p'),
  ('test.wallet.withdrawal', 'wallet', 'withdrawal'),
  ('test.payments.general', 'payments', '*'),
  ('test.payouts.general', 'payouts', '*')
) defaults(rule_code, product, channel)
ON CONFLICT DO NOTHING;

INSERT INTO financial_rule_limits(rule_version_id, dimension, minimum_minor, maximum_minor, period_seconds)
SELECT id, 'rolling_period',
  CASE channel WHEN 'p2p' THEN 10000 WHEN 'withdrawal' THEN 100000 ELSE 1 END,
  CASE channel WHEN 'p2p' THEN 5000000 WHEN 'withdrawal' THEN 10000000 ELSE 9000000000000000 END,
  86400
FROM financial_rule_versions
WHERE organization_id IS NULL
  AND rule_code IN ('test.wallet.p2p', 'test.wallet.withdrawal', 'test.payments.general', 'test.payouts.general')
ON CONFLICT (rule_version_id, dimension) DO NOTHING;

ALTER TABLE financial_rule_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_rule_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_risk_controls ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_live_activations ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_compliance_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_read ON financial_rule_versions FOR SELECT
  USING (organization_id IS NULL OR has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON financial_rule_limits FOR SELECT USING (
  EXISTS (SELECT 1 FROM financial_rule_versions r WHERE r.id = rule_version_id
    AND (r.organization_id IS NULL OR has_active_organization_membership(r.organization_id)))
);
CREATE POLICY tenant_read ON financial_approval_requests FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON financial_risk_controls FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON financial_live_activations FOR SELECT USING (has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON financial_compliance_snapshots FOR SELECT USING (has_active_organization_membership(organization_id));

ALTER TABLE financial_kyc_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON financial_rule_versions, financial_rule_limits, financial_approval_requests,
  financial_risk_controls, financial_live_activations, financial_compliance_snapshots,
  financial_kyc_evidence FROM anon, authenticated;
REVOKE ALL ON FUNCTION submit_financial_rule(UUID, UUID), decide_financial_rule(UUID, UUID, BOOLEAN, TEXT),
  enforce_financial_command(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION submit_financial_rule(UUID, UUID), decide_financial_rule(UUID, UUID, BOOLEAN, TEXT),
  enforce_financial_command(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT)
  TO service_role;
CREATE POLICY tenant_read ON financial_kyc_evidence FOR SELECT USING (has_active_organization_membership(organization_id));
REVOKE ALL ON FUNCTION
  place_financial_risk_control(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ),
  release_financial_risk_control(UUID, UUID, TEXT),
  request_financial_live_activation(UUID, UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, DATE, TIMESTAMPTZ),
  decide_financial_live_activation(UUID, UUID, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  place_financial_risk_control(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ),
  release_financial_risk_control(UUID, UUID, TEXT),
  request_financial_live_activation(UUID, UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, DATE, TIMESTAMPTZ),
  decide_financial_live_activation(UUID, UUID, BOOLEAN, TEXT)
  TO service_role;
