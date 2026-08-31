-- Consent-governed cross-tenant programme reporting scopes. This migration
-- deliberately exposes no aggregation or export function.
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS institutional_programme_reporting_scopes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  programme_organization_id UUID NOT NULL REFERENCES organizations(id),
  programme_id UUID NOT NULL REFERENCES institutional_programmes(id),
  participating_organization_id UUID NOT NULL REFERENCES organizations(id),
  purpose TEXT NOT NULL,
  permitted_metrics TEXT[] NOT NULL,
  disclosure_version TEXT NOT NULL,
  request_evidence_hash TEXT NOT NULL,
  consent_evidence_hash TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'granted', 'rejected', 'revoked', 'expired')),
  requested_by UUID NOT NULL REFERENCES users(id),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decided_by UUID REFERENCES users(id),
  decided_at TIMESTAMPTZ,
  decision_reason TEXT,
  effective_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_by UUID REFERENCES users(id),
  revoked_at TIMESTAMPTZ,
  revocation_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (programme_organization_id <> participating_organization_id),
  CHECK (cardinality(permitted_metrics) BETWEEN 1 AND 32),
  CHECK (expires_at > requested_at),
  CHECK (
    (status = 'pending' AND decided_by IS NULL AND decided_at IS NULL)
    OR (status = 'granted' AND decided_by IS NOT NULL AND decided_at IS NOT NULL
        AND consent_evidence_hash IS NOT NULL AND effective_at IS NOT NULL)
    OR (status = 'rejected' AND decided_by IS NOT NULL AND decided_at IS NOT NULL)
    OR (status = 'revoked' AND revoked_by IS NOT NULL AND revoked_at IS NOT NULL)
    OR status = 'expired'
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_programme_reporting_scope_open
  ON institutional_programme_reporting_scopes(
    programme_id, participating_organization_id
  ) WHERE status IN ('pending', 'granted');
CREATE INDEX IF NOT EXISTS idx_programme_reporting_scope_programme_org
  ON institutional_programme_reporting_scopes(
    programme_organization_id, programme_id, created_at DESC
  );
CREATE INDEX IF NOT EXISTS idx_programme_reporting_scope_participant_org
  ON institutional_programme_reporting_scopes(
    participating_organization_id, created_at DESC
  );

CREATE OR REPLACE FUNCTION request_programme_reporting_scope(
  p_programme_organization_id UUID,
  p_actor_id UUID,
  p_programme_id UUID,
  p_participating_organization_id UUID,
  p_purpose TEXT,
  p_permitted_metrics TEXT[],
  p_disclosure_version TEXT,
  p_request_evidence_hash TEXT,
  p_expires_at TIMESTAMPTZ,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS institutional_programme_reporting_scopes
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_scope institutional_programme_reporting_scopes;
  v_metrics TEXT[];
BEGIN
  IF p_programme_organization_id IS NULL OR p_actor_id IS NULL
     OR p_programme_id IS NULL OR p_participating_organization_id IS NULL
     OR p_programme_organization_id = p_participating_organization_id
     OR length(trim(COALESCE(p_purpose, ''))) NOT BETWEEN 10 AND 1000
     OR p_disclosure_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
     OR p_disclosure_version IS NULL
     OR p_request_evidence_hash IS NULL
     OR p_expires_at IS NULL
     OR p_request_evidence_hash !~ '^[a-f0-9]{64}$'
     OR p_expires_at <= p_occurred_at
     OR COALESCE(cardinality(p_permitted_metrics), 0) NOT BETWEEN 1 AND 32
     OR EXISTS (
       SELECT 1 FROM unnest(COALESCE(p_permitted_metrics, '{}'::TEXT[])) metric
       WHERE metric IS NULL OR metric <> trim(metric)
          OR metric !~ '^aggregate\.[a-z][a-z0-9_]*$'
     )
  THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_programme_organization_id
      AND user_id = p_actor_id AND status = 'active'
      AND role IN ('owner', 'admin', 'program_manager')
  ) THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_PERMISSION_DENIED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM institutional_programmes
    WHERE id = p_programme_id
      AND organization_id = p_programme_organization_id
      AND status IN ('draft', 'active')
  ) OR NOT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = p_participating_organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_TARGET_NOT_FOUND';
  END IF;

  WITH expired AS (
    UPDATE institutional_programme_reporting_scopes
    SET status = 'expired', updated_at = p_occurred_at
    WHERE programme_id = p_programme_id
      AND participating_organization_id = p_participating_organization_id
      AND status = 'pending' AND expires_at <= p_occurred_at
    RETURNING *
  )
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  )
  SELECT organization_id, p_actor_id, 'programme.reporting_scope.expired',
    'programme_reporting_scope', scope_id::TEXT,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'expired'), p_occurred_at
  FROM (
    SELECT programme_organization_id AS organization_id, id AS scope_id
    FROM expired
    UNION ALL
    SELECT participating_organization_id, id FROM expired
  ) evidence;
  SELECT array_agg(metric ORDER BY metric) INTO v_metrics
  FROM (SELECT DISTINCT unnest(p_permitted_metrics) metric) normalized;

  INSERT INTO institutional_programme_reporting_scopes(
    programme_organization_id, programme_id, participating_organization_id,
    purpose, permitted_metrics, disclosure_version, request_evidence_hash,
    requested_by, requested_at, expires_at, created_at, updated_at
  ) VALUES (
    p_programme_organization_id, p_programme_id,
    p_participating_organization_id, trim(p_purpose), v_metrics,
    p_disclosure_version, p_request_evidence_hash, p_actor_id,
    p_occurred_at, p_expires_at, p_occurred_at, p_occurred_at
  ) RETURNING * INTO v_scope;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    after_value, occurred_at
  ) VALUES
    (
      p_programme_organization_id, p_actor_id,
      'programme.reporting_scope.requested', 'programme_reporting_scope',
      v_scope.id::TEXT,
      jsonb_build_object(
        'programme_id', p_programme_id,
        'participating_organization_id', p_participating_organization_id,
        'purpose', v_scope.purpose,
        'permitted_metrics', to_jsonb(v_metrics),
        'disclosure_version', p_disclosure_version,
        'expires_at', p_expires_at,
        'row_level_access', false
      ), p_occurred_at
    ),
    (
      p_participating_organization_id, p_actor_id,
      'programme.reporting_scope.consent_requested',
      'programme_reporting_scope', v_scope.id::TEXT,
      jsonb_build_object(
        'programme_organization_id', p_programme_organization_id,
        'programme_id', p_programme_id,
        'purpose', v_scope.purpose,
        'permitted_metrics', to_jsonb(v_metrics),
        'disclosure_version', p_disclosure_version,
        'expires_at', p_expires_at,
        'row_level_access', false
      ), p_occurred_at
    );
  RETURN v_scope;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_ALREADY_OPEN';
END;
$$;

CREATE OR REPLACE FUNCTION decide_programme_reporting_scope(
  p_participating_organization_id UUID,
  p_actor_id UUID,
  p_scope_id UUID,
  p_decision TEXT,
  p_reason TEXT,
  p_consent_evidence_hash TEXT,
  p_effective_at TIMESTAMPTZ,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS institutional_programme_reporting_scopes
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_scope institutional_programme_reporting_scopes;
BEGIN
  IF p_decision NOT IN ('granted', 'rejected')
     OR length(trim(COALESCE(p_reason, ''))) NOT BETWEEN 3 AND 1000
     OR (p_decision = 'granted' AND (
       p_consent_evidence_hash !~ '^[a-f0-9]{64}$'
       OR p_effective_at IS NULL OR p_effective_at < p_occurred_at
     ))
  THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_DECISION_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_participating_organization_id
      AND user_id = p_actor_id AND status = 'active' AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_PERMISSION_DENIED';
  END IF;

  SELECT * INTO v_scope FROM institutional_programme_reporting_scopes
  WHERE id = p_scope_id
    AND participating_organization_id = p_participating_organization_id
    AND status = 'pending'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_NOT_FOUND';
  END IF;
  IF v_scope.expires_at <= p_occurred_at THEN
    UPDATE institutional_programme_reporting_scopes
    SET status = 'expired', updated_at = p_occurred_at
    WHERE id = v_scope.id;
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_EXPIRED';
  END IF;

  UPDATE institutional_programme_reporting_scopes SET
    status = p_decision,
    decided_by = p_actor_id,
    decided_at = p_occurred_at,
    decision_reason = trim(p_reason),
    consent_evidence_hash = CASE WHEN p_decision = 'granted'
      THEN p_consent_evidence_hash ELSE NULL END,
    effective_at = CASE WHEN p_decision = 'granted'
      THEN p_effective_at ELSE NULL END,
    updated_at = p_occurred_at
  WHERE id = v_scope.id RETURNING * INTO v_scope;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  ) VALUES
    (
      v_scope.participating_organization_id, p_actor_id,
      'programme.reporting_scope.' || p_decision,
      'programme_reporting_scope', v_scope.id::TEXT,
      jsonb_build_object('status', 'pending'),
      jsonb_build_object(
        'status', p_decision, 'reason', trim(p_reason),
        'effective_at', v_scope.effective_at,
        'expires_at', v_scope.expires_at,
        'row_level_access', false
      ), p_occurred_at
    ),
    (
      v_scope.programme_organization_id, p_actor_id,
      'programme.reporting_scope.' || p_decision,
      'programme_reporting_scope', v_scope.id::TEXT,
      jsonb_build_object('status', 'pending'),
      jsonb_build_object(
        'status', p_decision, 'reason', trim(p_reason),
        'effective_at', v_scope.effective_at,
        'expires_at', v_scope.expires_at,
        'row_level_access', false
      ), p_occurred_at
    );
  RETURN v_scope;
END;
$$;

CREATE OR REPLACE FUNCTION revoke_programme_reporting_scope(
  p_participating_organization_id UUID,
  p_actor_id UUID,
  p_scope_id UUID,
  p_reason TEXT,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS institutional_programme_reporting_scopes
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_scope institutional_programme_reporting_scopes;
BEGIN
  IF length(trim(COALESCE(p_reason, ''))) NOT BETWEEN 3 AND 1000 THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_REVOCATION_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_participating_organization_id
      AND user_id = p_actor_id AND status = 'active' AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_PERMISSION_DENIED';
  END IF;

  SELECT * INTO v_scope FROM institutional_programme_reporting_scopes
  WHERE id = p_scope_id
    AND participating_organization_id = p_participating_organization_id
    AND status = 'granted'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROGRAMME_REPORTING_SCOPE_NOT_FOUND';
  END IF;

  UPDATE institutional_programme_reporting_scopes SET
    status = 'revoked', revoked_by = p_actor_id,
    revoked_at = p_occurred_at, revocation_reason = trim(p_reason),
    updated_at = p_occurred_at
  WHERE id = v_scope.id RETURNING * INTO v_scope;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  ) VALUES
    (
      v_scope.participating_organization_id, p_actor_id,
      'programme.reporting_scope.revoked', 'programme_reporting_scope',
      v_scope.id::TEXT, jsonb_build_object('status', 'granted'),
      jsonb_build_object('status', 'revoked', 'reason', trim(p_reason)),
      p_occurred_at
    ),
    (
      v_scope.programme_organization_id, p_actor_id,
      'programme.reporting_scope.revoked', 'programme_reporting_scope',
      v_scope.id::TEXT, jsonb_build_object('status', 'granted'),
      jsonb_build_object('status', 'revoked', 'reason', trim(p_reason)),
      p_occurred_at
    );
  RETURN v_scope;
END;
$$;

REVOKE ALL ON TABLE institutional_programme_reporting_scopes
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE institutional_programme_reporting_scopes TO service_role;
REVOKE ALL ON FUNCTION request_programme_reporting_scope(
  UUID, UUID, UUID, UUID, TEXT, TEXT[], TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_programme_reporting_scope(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION revoke_programme_reporting_scope(
  UUID, UUID, UUID, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION request_programme_reporting_scope(
  UUID, UUID, UUID, UUID, TEXT, TEXT[], TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_programme_reporting_scope(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION revoke_programme_reporting_scope(
  UUID, UUID, UUID, TEXT, TIMESTAMPTZ
) TO service_role;
