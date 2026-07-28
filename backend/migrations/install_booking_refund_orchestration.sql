-- BR-01..BR-12: tenant-safe booking cancellation and canonical refund orchestration.

CREATE TABLE IF NOT EXISTS booking_cancellations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  acting_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL UNIQUE REFERENCES bookings(id),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
  previous_status TEXT NOT NULL,
  policy_version TEXT NOT NULL DEFAULT 'BR-2026-07-28',
  timing TEXT NOT NULL CHECK (timing IN ('pre_start', 'on_or_after_start')),
  outcome TEXT NOT NULL CHECK (outcome IN (
    'refund_not_required', 'refund_created', 'refund_processing',
    'refund_succeeded', 'refund_failed', 'manual_review'
  )),
  payment_id UUID REFERENCES payments(id),
  refund_id UUID UNIQUE REFERENCES payment_refunds(id),
  refund_amount_minor BIGINT CHECK (refund_amount_minor IS NULL OR refund_amount_minor > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'NGN' CHECK (currency ~ '^[A-Z]{3}$'),
  manual_review_reason TEXT,
  policy_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (acting_organization_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_booking_cancellations_tenant
  ON booking_cancellations(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_cancellations_refund
  ON booking_cancellations(refund_id) WHERE refund_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS booking_refund_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  cancellation_id UUID NOT NULL REFERENCES booking_cancellations(id),
  payment_id UUID NOT NULL REFERENCES payments(id),
  requested_by UUID NOT NULL REFERENCES users(id),
  decided_by UUID REFERENCES users(id),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'NGN' CHECK (currency ~ '^[A-Z]{3}$'),
  reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 500),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'approved', 'rejected')),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  decision_reason TEXT,
  decision_idempotency_key TEXT CHECK (decision_idempotency_key IS NULL OR length(decision_idempotency_key) BETWEEN 8 AND 160),
  decision_hash VARCHAR(64) CHECK (decision_hash IS NULL OR decision_hash ~ '^[a-f0-9]{64}$'),
  refund_id UUID UNIQUE REFERENCES payment_refunds(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decided_at TIMESTAMPTZ,
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (organization_id, decision_idempotency_key),
  UNIQUE (cancellation_id)
);

CREATE TABLE IF NOT EXISTS legacy_refund_quarantine (
  legacy_refund_id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID REFERENCES bookings(id),
  amount_major NUMERIC(10,2) NOT NULL,
  legacy_status TEXT NOT NULL,
  payment_reference TEXT,
  reason TEXT,
  source_created_at TIMESTAMPTZ,
  quarantined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  quarantine_reason TEXT NOT NULL DEFAULT 'unverified_legacy_refund'
);

INSERT INTO legacy_refund_quarantine(
  legacy_refund_id, organization_id, booking_id, amount_major, legacy_status,
  payment_reference, reason, source_created_at
)
SELECT r.id, r.organization_id, r.booking_id, r.amount, r.status,
  r.payment_reference, r.reason, r.created_at
FROM refunds r
ON CONFLICT (legacy_refund_id) DO NOTHING;

CREATE OR REPLACE FUNCTION block_legacy_refund_writes() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Legacy refunds are read-only; use canonical payment_refunds';
END;
$$;
DROP TRIGGER IF EXISTS block_legacy_refund_writes_trigger ON refunds;
CREATE TRIGGER block_legacy_refund_writes_trigger
  BEFORE INSERT OR UPDATE OR DELETE ON refunds
  FOR EACH ROW EXECUTE FUNCTION block_legacy_refund_writes();

CREATE OR REPLACE FUNCTION log_booking_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_actor TEXT;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    v_actor := current_setting('microfams.actor_id', TRUE);
    INSERT INTO booking_status_history (booking_id, old_status, new_status, changed_by, reason)
    VALUES (
      NEW.id, OLD.status, NEW.status,
      CASE WHEN v_actor ~ '^[0-9a-f-]{36}$' THEN v_actor::UUID ELSE NEW.cancelled_by END,
      NEW.rejection_reason
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION cancel_booking_with_refund(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_reason TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_booking bookings;
  v_owner UUID;
  v_timezone TEXT;
  v_existing booking_cancellations;
  v_payment payments;
  v_refund payment_refunds;
  v_cancellation booking_cancellations;
  v_hash TEXT;
  v_refunded BIGINT;
  v_remaining BIGINT;
  v_timing TEXT;
  v_outcome TEXT;
  v_manual_reason TEXT;
BEGIN
  IF length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 2 AND 500 THEN
    RAISE EXCEPTION 'Cancellation reason must contain 2 to 500 characters';
  END IF;
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Idempotency key must contain 8 to 160 characters';
  END IF;

  v_hash := encode(digest(convert_to(concat_ws('|', p_booking_id, p_acting_organization_id,
    p_actor_id, btrim(p_reason)), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_cancellations
    WHERE acting_organization_id = p_acting_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash THEN
      RAISE EXCEPTION 'Cancellation replay changed the original request';
    END IF;
    RETURN to_jsonb(v_existing) || jsonb_build_object('idempotency_replay', TRUE);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_booking_id::TEXT, 0));
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
  SELECT p.owner_id, o.timezone INTO v_owner, v_timezone
  FROM properties p
  JOIN organizations o ON o.id = v_booking.organization_id
  WHERE p.id = v_booking.property_id;

  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships m
    WHERE m.organization_id = p_acting_organization_id
      AND m.user_id = p_actor_id AND m.status = 'active'
  ) THEN RAISE EXCEPTION 'Booking cancellation is not authorized'; END IF;

  IF NOT (
    (p_acting_organization_id = v_booking.organization_id AND p_actor_id = v_booking.farmer_id)
    OR (p_acting_organization_id = v_booking.provider_organization_id AND p_actor_id = v_owner)
    OR (
      p_acting_organization_id IN (v_booking.organization_id, v_booking.provider_organization_id)
      AND EXISTS (
        SELECT 1 FROM organization_memberships m
        WHERE m.organization_id = p_acting_organization_id AND m.user_id = p_actor_id
          AND m.status = 'active'
          AND ('booking.cancel.support' = ANY(m.permissions) OR 'booking.*' = ANY(m.permissions))
      )
    )
  ) THEN RAISE EXCEPTION 'Booking cancellation is not authorized'; END IF;

  IF v_booking.status NOT IN ('pending_payment', 'pending', 'confirmed') THEN
    RAISE EXCEPTION 'Booking status % cannot be cancelled', v_booking.status;
  END IF;

  v_timing := CASE
    WHEN (NOW() AT TIME ZONE COALESCE(v_timezone, 'Africa/Lagos'))::DATE < v_booking.start_date
      THEN 'pre_start' ELSE 'on_or_after_start' END;

  SELECT * INTO v_payment FROM payments
  WHERE organization_id = v_booking.organization_id
    AND source_type = 'booking' AND source_id = v_booking.id
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF v_booking.payment_status <> 'paid' THEN
    v_outcome := 'refund_not_required';
  ELSIF v_payment.id IS NULL OR v_payment.state NOT IN ('succeeded', 'partially_refunded') THEN
    v_outcome := 'manual_review';
    v_manual_reason := 'paid_booking_without_refundable_canonical_payment';
  ELSIF v_timing = 'on_or_after_start' THEN
    v_outcome := 'manual_review';
    v_manual_reason := 'booking_started';
  ELSE
    SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
    FROM payment_refunds WHERE payment_id = v_payment.id
      AND state IN ('created', 'submitted', 'processing', 'succeeded');
    v_remaining := v_payment.amount_minor - v_refunded;
    IF v_remaining <= 0 THEN
      v_outcome := 'refund_not_required';
    ELSE
      v_refund := create_payment_refund(
        v_payment.id,
        'BKR-' || replace(v_booking.id::TEXT, '-', ''),
        'booking-cancel:' || md5(p_idempotency_key),
        v_remaining,
        'booking_pre_start_cancellation',
        btrim(p_reason),
        p_actor_id,
        'BR-2026-07-28:auto'
      );
      v_outcome := CASE v_refund.state
        WHEN 'succeeded' THEN 'refund_succeeded'
        WHEN 'failed' THEN 'refund_failed'
        WHEN 'created' THEN 'refund_created'
        ELSE 'refund_processing' END;
    END IF;
  END IF;

  PERFORM set_config('microfams.actor_id', p_actor_id::TEXT, TRUE);
  UPDATE bookings SET status = 'cancelled', rejection_reason = btrim(p_reason),
    cancelled_by = p_actor_id, cancelled_at = NOW(), updated_at = NOW()
  WHERE id = v_booking.id;

  INSERT INTO booking_cancellations(
    organization_id, provider_organization_id, acting_organization_id, booking_id,
    actor_id, idempotency_key, request_hash, correlation_id, reason, previous_status,
    timing, outcome, payment_id, refund_id, refund_amount_minor, currency,
    manual_review_reason, policy_snapshot
  ) VALUES (
    v_booking.organization_id, v_booking.provider_organization_id, p_acting_organization_id,
    v_booking.id, p_actor_id, p_idempotency_key, v_hash, p_correlation_id, btrim(p_reason),
    v_booking.status, v_timing, v_outcome, v_payment.id, v_refund.id,
    v_refund.amount_minor, COALESCE(v_payment.currency, 'NGN'), v_manual_reason,
    jsonb_build_object('version', 'BR-2026-07-28', 'timezone', v_timezone,
      'booking_start_date', v_booking.start_date, 'evaluated_at', NOW())
  ) RETURNING * INTO v_cancellation;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, before_value, after_value
  ) VALUES (
    v_booking.organization_id, p_actor_id, 'booking.cancelled', 'booking', v_booking.id::TEXT,
    jsonb_build_object('status', v_booking.status),
    jsonb_build_object('status', 'cancelled', 'outcome', v_outcome,
      'refund_id', v_refund.id, 'correlation_id', p_correlation_id)
  );
  IF p_acting_organization_id <> v_booking.organization_id THEN
    INSERT INTO organization_audit_log(
      organization_id, actor_id, action, resource_type, resource_id, before_value, after_value
    ) VALUES (
      p_acting_organization_id, p_actor_id, 'booking.cancelled', 'booking', v_booking.id::TEXT,
      jsonb_build_object('status', v_booking.status),
      jsonb_build_object('status', 'cancelled', 'customer_organization_id', v_booking.organization_id,
        'outcome', v_outcome, 'correlation_id', p_correlation_id)
    );
  END IF;

  RETURN to_jsonb(v_cancellation) || jsonb_build_object('idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION sync_booking_cancellation_refund(p_refund_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_refund payment_refunds; v_result booking_cancellations;
BEGIN
  SELECT * INTO v_refund FROM payment_refunds WHERE id = p_refund_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found'; END IF;
  UPDATE booking_cancellations SET
    outcome = CASE v_refund.state
      WHEN 'created' THEN 'refund_created'
      WHEN 'succeeded' THEN 'refund_succeeded'
      WHEN 'failed' THEN 'refund_failed'
      WHEN 'cancelled' THEN 'refund_failed'
      ELSE 'refund_processing' END,
    updated_at = NOW()
  WHERE refund_id = v_refund.id RETURNING * INTO v_result;
  RETURN CASE WHEN v_result.id IS NULL THEN NULL ELSE to_jsonb(v_result) END;
END;
$$;

CREATE OR REPLACE FUNCTION propose_booking_refund(
  p_cancellation_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_amount_minor BIGINT, p_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c booking_cancellations; v_payment payments; v_existing booking_refund_approvals;
  v_result booking_refund_approvals; v_reserved BIGINT;
BEGIN
  SELECT * INTO v_existing FROM booking_refund_approvals
    WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.cancellation_id <> p_cancellation_id OR v_existing.requested_by <> p_actor_id
      OR v_existing.amount_minor <> p_amount_minor OR v_existing.reason <> btrim(p_reason)
    THEN RAISE EXCEPTION 'Refund proposal replay changed the original request'; END IF;
    RETURN to_jsonb(v_existing) || jsonb_build_object('idempotency_replay', TRUE); END IF;
  IF NOT has_financial_permission(p_organization_id, p_actor_id, 'financial.refunds.create') THEN
    RAISE EXCEPTION 'Refund proposal is not authorized'; END IF;
  SELECT * INTO v_c FROM booking_cancellations
    WHERE id = p_cancellation_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND OR v_c.outcome <> 'manual_review' OR v_c.payment_id IS NULL THEN
    RAISE EXCEPTION 'Cancellation is not eligible for manual refund review'; END IF;
  SELECT * INTO v_payment FROM payments WHERE id = v_c.payment_id FOR UPDATE;
  SELECT COALESCE(sum(amount_minor), 0) INTO v_reserved FROM payment_refunds
    WHERE payment_id = v_payment.id AND state IN ('created', 'submitted', 'processing', 'succeeded');
  IF p_amount_minor <= 0 OR p_amount_minor > v_payment.amount_minor - v_reserved THEN
    RAISE EXCEPTION 'Refund exceeds remaining refundable amount'; END IF;
  INSERT INTO booking_refund_approvals(
    organization_id, cancellation_id, payment_id, requested_by, amount_minor,
    currency, reason, idempotency_key
  ) VALUES (p_organization_id, v_c.id, v_payment.id, p_actor_id, p_amount_minor,
    v_payment.currency, btrim(p_reason), p_idempotency_key)
  RETURNING * INTO v_result;
  RETURN to_jsonb(v_result) || jsonb_build_object('idempotency_replay', FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_refund(
  p_approval_id UUID, p_organization_id UUID, p_actor_id UUID,
  p_approve BOOLEAN, p_decision_reason TEXT, p_idempotency_key TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_approval booking_refund_approvals; v_refund payment_refunds; v_c booking_cancellations; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization_id, p_actor_id, 'financial.refunds.approve') THEN
    RAISE EXCEPTION 'Refund decision is not authorized'; END IF;
  IF length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR length(btrim(COALESCE(p_decision_reason, ''))) NOT BETWEEN 2 AND 500
  THEN RAISE EXCEPTION 'Refund decision idempotency key or reason is invalid'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|', p_approval_id, p_actor_id,
    p_approve, btrim(p_decision_reason)), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_approval FROM booking_refund_approvals
    WHERE id = p_approval_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund approval not found'; END IF;
  IF v_approval.state <> 'pending' THEN
    IF v_approval.decision_idempotency_key = p_idempotency_key AND v_approval.decision_hash = v_hash
    THEN RETURN to_jsonb(v_approval) || jsonb_build_object('idempotency_replay', TRUE); END IF;
    RAISE EXCEPTION 'Refund decision has already been recorded';
  END IF;
  IF v_approval.requested_by = p_actor_id THEN RAISE EXCEPTION 'Maker cannot approve own refund'; END IF;
  IF p_approve THEN
    v_refund := create_payment_refund(
      v_approval.payment_id,
      'BKR-MAN-' || replace(v_approval.id::TEXT, '-', ''),
      p_idempotency_key,
      v_approval.amount_minor,
      'booking_manual_approval',
      v_approval.reason,
      p_actor_id,
      v_approval.id::TEXT
    );
    UPDATE booking_refund_approvals SET state = 'approved', decided_by = p_actor_id,
      decision_reason = btrim(p_decision_reason), decision_idempotency_key = p_idempotency_key,
      decision_hash = v_hash, refund_id = v_refund.id, decided_at = NOW()
    WHERE id = v_approval.id RETURNING * INTO v_approval;
    UPDATE booking_cancellations SET refund_id = v_refund.id,
      refund_amount_minor = v_refund.amount_minor, outcome = 'refund_created', updated_at = NOW()
    WHERE id = v_approval.cancellation_id RETURNING * INTO v_c;
  ELSE
    UPDATE booking_refund_approvals SET state = 'rejected', decided_by = p_actor_id,
      decision_reason = btrim(p_decision_reason), decision_idempotency_key = p_idempotency_key,
      decision_hash = v_hash, decided_at = NOW()
    WHERE id = v_approval.id RETURNING * INTO v_approval;
  END IF;
  RETURN to_jsonb(v_approval);
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'financial.refunds.approve', 'booking.cancel.support'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_cancellations ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_refund_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE legacy_refund_quarantine ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_cancellations, booking_refund_approvals, legacy_refund_quarantine FROM anon, authenticated;
REVOKE ALL ON FUNCTION cancel_booking_with_refund(UUID, UUID, UUID, TEXT, TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION sync_booking_cancellation_refund(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION propose_booking_refund(UUID, UUID, UUID, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_booking_refund(UUID, UUID, UUID, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_booking_with_refund(UUID, UUID, UUID, TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION sync_booking_cancellation_refund(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION propose_booking_refund(UUID, UUID, UUID, BIGINT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_refund(UUID, UUID, UUID, BOOLEAN, TEXT, TEXT) TO service_role;
