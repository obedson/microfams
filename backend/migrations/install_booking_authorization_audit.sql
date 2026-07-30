-- BS-10A: durable organization-scoped booking authorization decisions.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS booking_authorization_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  actor_id UUID NOT NULL REFERENCES users(id),
  operation TEXT NOT NULL CHECK (operation ~ '^booking\.[a-z0-9_.-]{2,100}$'),
  required_permission TEXT NOT NULL
    CHECK (required_permission ~ '^(booking|financial)\.[a-z0-9.*_-]{2,120}$'),
  resource_type TEXT NOT NULL CHECK (resource_type ~ '^[a-z][a-z0-9_.-]{1,80}$'),
  resource_reference TEXT,
  resource_fingerprint VARCHAR(64)
    CHECK (resource_fingerprint IS NULL OR resource_fingerprint ~ '^[a-f0-9]{64}$'),
  outcome TEXT NOT NULL CHECK (outcome IN ('allowed', 'denied')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,80}$'),
  correlation_id UUID NOT NULL,
  idempotency_key_hash VARCHAR(64)
    CHECK (idempotency_key_hash IS NULL OR idempotency_key_hash ~ '^[a-f0-9]{64}$'),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    (outcome = 'allowed' AND reason_code = 'PERMISSION_ALLOWED')
    OR
    (outcome = 'denied' AND reason_code = 'MEMBERSHIP_OR_PERMISSION_DENIED')
  ),
  CHECK (outcome = 'allowed' OR resource_reference IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_booking_authorization_tenant_time
  ON booking_authorization_decisions(organization_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_authorization_actor_time
  ON booking_authorization_decisions(actor_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_authorization_denials
  ON booking_authorization_decisions(organization_id, required_permission, occurred_at DESC)
  WHERE outcome = 'denied';

CREATE OR REPLACE FUNCTION protect_booking_authorization_decision()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'BOOKING_AUTHORIZATION_EVIDENCE_IMMUTABLE';
  END IF;
  IF current_setting('microfams.booking_authorization_engine', TRUE)
    IS DISTINCT FROM 'on'
  THEN RAISE EXCEPTION 'BOOKING_AUTHORIZATION_ENGINE_REQUIRED'; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS booking_authorization_decisions_append_only
  ON booking_authorization_decisions;
CREATE TRIGGER booking_authorization_decisions_append_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_authorization_decisions
  FOR EACH ROW EXECUTE FUNCTION protect_booking_authorization_decision();

CREATE OR REPLACE FUNCTION evaluate_booking_authorization(
  p_organization_id UUID,
  p_actor_id UUID,
  p_required_permission TEXT,
  p_operation TEXT,
  p_resource_type TEXT,
  p_resource_id TEXT,
  p_correlation_id UUID,
  p_idempotency_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_allowed BOOLEAN;
  v_reason TEXT;
  v_decision booking_authorization_decisions;
  v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_actor_id IS NULL OR p_correlation_id IS NULL
    OR p_operation !~ '^booking\.[a-z0-9_.-]{2,100}$'
    OR p_required_permission !~ '^(booking|financial)\.[a-z0-9.*_-]{2,120}$'
    OR p_resource_type !~ '^[a-z][a-z0-9_.-]{1,80}$'
    OR length(COALESCE(p_resource_id, '')) > 200
    OR length(COALESCE(p_idempotency_key, '')) > 160
  THEN RAISE EXCEPTION 'BOOKING_AUTHORIZATION_REQUEST_INVALID'; END IF;

  v_allowed := has_booking_permission(
    p_organization_id, p_actor_id, p_required_permission
  );
  v_reason := CASE WHEN v_allowed
    THEN 'PERMISSION_ALLOWED'
    ELSE 'MEMBERSHIP_OR_PERMISSION_DENIED'
  END;

  v_previous := current_setting('microfams.booking_authorization_engine', TRUE);
  PERFORM set_config('microfams.booking_authorization_engine', 'on', TRUE);
  INSERT INTO booking_authorization_decisions(
    organization_id, actor_id, operation, required_permission,
    resource_type, resource_reference, resource_fingerprint,
    outcome, reason_code, correlation_id, idempotency_key_hash
  ) VALUES (
    p_organization_id, p_actor_id, p_operation, p_required_permission,
    p_resource_type,
    CASE WHEN v_allowed THEN NULLIF(p_resource_id, '') ELSE NULL END,
    CASE WHEN NULLIF(p_resource_id, '') IS NULL THEN NULL
      ELSE encode(digest(convert_to(p_resource_id, 'UTF8'), 'sha256'), 'hex') END,
    CASE WHEN v_allowed THEN 'allowed' ELSE 'denied' END,
    v_reason, p_correlation_id,
    CASE WHEN NULLIF(p_idempotency_key, '') IS NULL THEN NULL
      ELSE encode(digest(convert_to(p_idempotency_key, 'UTF8'), 'sha256'), 'hex') END
  ) RETURNING * INTO v_decision;
  PERFORM set_config(
    'microfams.booking_authorization_engine', COALESCE(v_previous, ''), TRUE
  );

  RETURN jsonb_build_object(
    'allowed', v_allowed,
    'decision_id', v_decision.id,
    'reason_code', v_reason,
    'correlation_id', p_correlation_id
  );
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'booking.disputes.open',
    'booking.disputes.review',
    'booking.disputes.resolve',
    'booking.disputes.approve',
    'booking.settlements.read',
    'booking.settlements.release',
    'booking.payouts.read',
    'booking.payouts.service'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_authorization_decisions ENABLE ROW LEVEL SECURITY;
CREATE POLICY booking_authorization_tenant_read
  ON booking_authorization_decisions FOR SELECT
  USING (has_active_organization_membership(organization_id));

REVOKE ALL ON booking_authorization_decisions FROM anon, authenticated;
GRANT SELECT ON booking_authorization_decisions TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_authorization_decisions FROM service_role;
REVOKE ALL ON FUNCTION protect_booking_authorization_decision()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION evaluate_booking_authorization(
  UUID, UUID, TEXT, TEXT, TEXT, TEXT, UUID, TEXT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION evaluate_booking_authorization(
  UUID, UUID, TEXT, TEXT, TEXT, TEXT, UUID, TEXT
) TO service_role;
