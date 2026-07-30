-- BS-12B: durable tenant-aware booking notification outbox and delivery leases.

SET search_path = public, extensions;

ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id),
  ADD COLUMN IF NOT EXISTS source_type TEXT,
  ADD COLUMN IF NOT EXISTS source_id UUID;
CREATE UNIQUE INDEX IF NOT EXISTS uq_notifications_domain_source
  ON notifications(user_id, source_type, source_id)
  WHERE source_type IS NOT NULL AND source_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS booking_domain_notification_outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  recipient_organization_id UUID NOT NULL REFERENCES organizations(id),
  booking_id UUID NOT NULL REFERENCES bookings(id),
  settlement_contract_id UUID REFERENCES booking_settlement_contracts(id),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'payment_custody', 'service_completed', 'dispute_deadline',
    'dispute_opened', 'evidence_requested', 'resolution_proposed',
    'resolution_approved', 'refund_state', 'payout_state',
    'reversal', 'recovery'
  )),
  event_key TEXT NOT NULL UNIQUE CHECK (length(event_key) BETWEEN 8 AND 240),
  public_payload JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(public_payload) = 'object'),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'leased', 'retry', 'delivered', 'dead_letter')),
  available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 20),
  max_attempts INTEGER NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 20),
  lease_owner TEXT,
  lease_expires_at TIMESTAMPTZ,
  failure_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivered_at TIMESTAMPTZ,
  dead_lettered_at TIMESTAMPTZ,
  CHECK (
    (state = 'leased' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR (state <> 'leased' AND lease_owner IS NULL AND lease_expires_at IS NULL)
  ),
  CHECK ((state = 'delivered') = (delivered_at IS NOT NULL)),
  CHECK ((state = 'dead_letter') = (dead_lettered_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_booking_notification_outbox_claim
  ON booking_domain_notification_outbox(
    state, next_attempt_at, available_at, created_at, id
  ) WHERE state IN ('queued', 'retry', 'leased');
CREATE INDEX IF NOT EXISTS idx_booking_notification_outbox_tenant
  ON booking_domain_notification_outbox(
    recipient_organization_id, booking_id, created_at DESC
  );

CREATE OR REPLACE FUNCTION protect_booking_notification_outbox() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_notification_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'BOOKING_NOTIFICATION_ENGINE_REQUIRED';
END;
$$;
DROP TRIGGER IF EXISTS booking_notification_outbox_engine_only
  ON booking_domain_notification_outbox;
CREATE TRIGGER booking_notification_outbox_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_domain_notification_outbox
  FOR EACH ROW EXECUTE FUNCTION protect_booking_notification_outbox();

CREATE OR REPLACE FUNCTION enqueue_booking_domain_notification(
  p_organization_id UUID,
  p_recipient_organization_id UUID,
  p_booking_id UUID,
  p_settlement_contract_id UUID,
  p_event_type TEXT,
  p_event_key TEXT,
  p_public_payload JSONB,
  p_available_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id UUID;
  v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_recipient_organization_id IS NULL
    OR p_booking_id IS NULL
    OR p_event_type NOT IN (
      'payment_custody', 'service_completed', 'dispute_deadline',
      'dispute_opened', 'evidence_requested', 'resolution_proposed',
      'resolution_approved', 'refund_state', 'payout_state',
      'reversal', 'recovery'
    )
    OR length(COALESCE(p_event_key, '')) NOT BETWEEN 8 AND 240
    OR jsonb_typeof(COALESCE(p_public_payload, '{}'::JSONB)) <> 'object'
  THEN
    RAISE EXCEPTION 'BOOKING_NOTIFICATION_EVENT_INVALID';
  END IF;
  v_previous := current_setting('microfams.booking_notification_engine', TRUE);
  PERFORM set_config('microfams.booking_notification_engine', 'on', TRUE);
  INSERT INTO booking_domain_notification_outbox(
    organization_id, recipient_organization_id, booking_id,
    settlement_contract_id, event_type, event_key, public_payload,
    available_at, next_attempt_at
  ) VALUES (
    p_organization_id, p_recipient_organization_id, p_booking_id,
    p_settlement_contract_id, p_event_type, p_event_key,
    COALESCE(p_public_payload, '{}'::JSONB),
    COALESCE(p_available_at, NOW()), COALESCE(p_available_at, NOW())
  )
  ON CONFLICT (event_key) DO UPDATE SET event_key = EXCLUDED.event_key
  RETURNING id INTO v_id;
  PERFORM set_config(
    'microfams.booking_notification_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION queue_booking_contract_notifications() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_available TIMESTAMPTZ;
BEGIN
  IF OLD.funded_at IS NULL AND NEW.funded_at IS NOT NULL THEN
    PERFORM enqueue_booking_domain_notification(
      NEW.organization_id, recipient, NEW.booking_id, NEW.id,
      'payment_custody', concat_ws(':', 'booking', NEW.booking_id, 'payment_custody', recipient),
      jsonb_build_object('settlement_state', NEW.state, 'currency', NEW.currency),
      NOW()
    )
    FROM unnest(ARRAY[NEW.organization_id, NEW.provider_organization_id]) recipient;
  END IF;
  IF OLD.completed_at IS NULL AND NEW.completed_at IS NOT NULL THEN
    PERFORM enqueue_booking_domain_notification(
      NEW.organization_id, recipient, NEW.booking_id, NEW.id,
      'service_completed', concat_ws(':', 'booking', NEW.booking_id, 'service_completed', recipient),
      jsonb_build_object(
        'completed_at', NEW.completed_at,
        'dispute_deadline_at', NEW.dispute_deadline_at
      ),
      NOW()
    )
    FROM unnest(ARRAY[NEW.organization_id, NEW.provider_organization_id]) recipient;
    v_available := GREATEST(
      NOW(), COALESCE(NEW.dispute_deadline_at - INTERVAL '24 hours', NOW())
    );
    PERFORM enqueue_booking_domain_notification(
      NEW.organization_id, recipient, NEW.booking_id, NEW.id,
      'dispute_deadline', concat_ws(':', 'booking', NEW.booking_id, 'dispute_deadline', recipient),
      jsonb_build_object('dispute_deadline_at', NEW.dispute_deadline_at),
      v_available
    )
    FROM unnest(ARRAY[NEW.organization_id, NEW.provider_organization_id]) recipient;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_contract_notification_events
  ON booking_settlement_contracts;
CREATE TRIGGER booking_contract_notification_events
  AFTER UPDATE ON booking_settlement_contracts
  FOR EACH ROW EXECUTE FUNCTION queue_booking_contract_notifications();

CREATE OR REPLACE FUNCTION queue_booking_dispute_notification() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM enqueue_booking_domain_notification(
    NEW.organization_id, recipient, NEW.booking_id, NEW.settlement_contract_id,
    'dispute_opened', concat_ws(':', 'dispute', NEW.id, 'opened', recipient),
    jsonb_build_object(
      'dispute_id', NEW.id,
      'contested_amount_minor', NEW.contested_amount_minor,
      'currency', NEW.currency,
      'response_deadline_at', NEW.response_deadline_at
    ),
    NOW()
  )
  FROM unnest(ARRAY[NEW.organization_id, NEW.provider_organization_id]) recipient;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_dispute_notification_events ON booking_disputes;
CREATE TRIGGER booking_dispute_notification_events
  AFTER INSERT ON booking_disputes
  FOR EACH ROW EXECUTE FUNCTION queue_booking_dispute_notification();

CREATE OR REPLACE FUNCTION queue_booking_dispute_event_notification()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dispute booking_disputes;
  v_type TEXT;
BEGIN
  SELECT * INTO v_dispute FROM booking_disputes WHERE id = NEW.dispute_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_type := CASE
    WHEN NEW.event_type = 'state_changed'
      AND NEW.to_state = 'evidence_collection' THEN 'evidence_requested'
    WHEN NEW.event_type = 'resolution_proposed' THEN 'resolution_proposed'
    WHEN NEW.event_type = 'resolved' THEN 'resolution_approved'
    ELSE NULL
  END;
  IF v_type IS NULL THEN RETURN NEW; END IF;
  PERFORM enqueue_booking_domain_notification(
    v_dispute.organization_id, recipient, v_dispute.booking_id,
    v_dispute.settlement_contract_id, v_type,
    concat_ws(':', 'dispute_event', NEW.id, v_type, recipient),
    jsonb_build_object(
      'dispute_id', NEW.dispute_id,
      'from_state', NEW.from_state,
      'to_state', NEW.to_state,
      'occurred_at', NEW.occurred_at
    ),
    NOW()
  )
  FROM unnest(
    ARRAY[v_dispute.organization_id, v_dispute.provider_organization_id]
  ) recipient;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_dispute_event_notification_events
  ON booking_dispute_events;
CREATE TRIGGER booking_dispute_event_notification_events
  AFTER INSERT ON booking_dispute_events
  FOR EACH ROW EXECUTE FUNCTION queue_booking_dispute_event_notification();

CREATE OR REPLACE FUNCTION queue_booking_refund_notification() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.state IS NOT DISTINCT FROM NEW.state THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_contract
  FROM booking_settlement_contracts WHERE payment_id = NEW.payment_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  PERFORM enqueue_booking_domain_notification(
    v_contract.organization_id, recipient, v_contract.booking_id, v_contract.id,
    'refund_state', concat_ws(':', 'refund', NEW.id, NEW.state, recipient),
    jsonb_build_object(
      'refund_id', NEW.id,
      'amount_minor', NEW.amount_minor,
      'currency', NEW.currency,
      'state', NEW.state
    ),
    NOW()
  )
  FROM unnest(
    ARRAY[v_contract.organization_id, v_contract.provider_organization_id]
  ) recipient;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_refund_notification_events ON payment_refunds;
CREATE TRIGGER booking_refund_notification_events
  AFTER INSERT OR UPDATE ON payment_refunds
  FOR EACH ROW EXECUTE FUNCTION queue_booking_refund_notification();

CREATE OR REPLACE FUNCTION queue_booking_payout_notification() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
BEGIN
  IF NEW.source_type <> 'booking_settlement'
    OR (TG_OP = 'UPDATE' AND OLD.state IS NOT DISTINCT FROM NEW.state)
  THEN RETURN NEW; END IF;
  SELECT contract.* INTO v_contract
  FROM booking_settlement_releases AS release
  JOIN booking_settlement_contracts AS contract
    ON contract.id = release.settlement_contract_id
  WHERE release.id = NEW.booking_settlement_release_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  PERFORM enqueue_booking_domain_notification(
    v_contract.organization_id, v_contract.provider_organization_id,
    v_contract.booking_id, v_contract.id,
    'payout_state',
    concat_ws(':', 'payout', NEW.id, NEW.state, v_contract.provider_organization_id),
    jsonb_build_object(
      'payout_id', NEW.id,
      'amount_minor', NEW.amount_minor,
      'currency', NEW.currency,
      'state', NEW.state,
      'destination_masked', NEW.beneficiary_masked
    ),
    NOW()
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_payout_notification_events ON payouts;
CREATE TRIGGER booking_payout_notification_events
  AFTER INSERT OR UPDATE ON payouts
  FOR EACH ROW EXECUTE FUNCTION queue_booking_payout_notification();

CREATE OR REPLACE FUNCTION queue_booking_reversal_notification() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
BEGIN
  SELECT * INTO v_contract
  FROM booking_settlement_contracts WHERE payment_id = NEW.payment_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  PERFORM enqueue_booking_domain_notification(
    v_contract.organization_id, recipient, v_contract.booking_id, v_contract.id,
    'reversal', concat_ws(':', 'reversal', NEW.id, recipient),
    jsonb_build_object(
      'reversal_id', NEW.id,
      'amount_minor', NEW.amount_minor,
      'currency', NEW.currency,
      'occurred_at', NEW.occurred_at
    ),
    NOW()
  )
  FROM unnest(
    ARRAY[v_contract.organization_id, v_contract.provider_organization_id]
  ) recipient;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_reversal_notification_events
  ON payment_reversals;
CREATE TRIGGER booking_reversal_notification_events
  AFTER INSERT ON payment_reversals
  FOR EACH ROW EXECUTE FUNCTION queue_booking_reversal_notification();

CREATE OR REPLACE FUNCTION queue_booking_recovery_notification() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_case booking_recovery_cases;
  v_contract booking_settlement_contracts;
BEGIN
  SELECT * INTO v_case
  FROM booking_recovery_cases WHERE id = NEW.recovery_case_id;
  SELECT * INTO v_contract
  FROM booking_settlement_contracts WHERE id = v_case.settlement_contract_id;
  IF v_contract.id IS NULL THEN RETURN NEW; END IF;
  PERFORM enqueue_booking_domain_notification(
    v_contract.organization_id, recipient, v_contract.booking_id, v_contract.id,
    'recovery', concat_ws(':', 'recovery_event', NEW.id, recipient),
    jsonb_build_object(
      'recovery_case_id', NEW.recovery_case_id,
      'event_type', NEW.event_type,
      'amount_minor', NEW.amount_minor,
      'currency', NEW.currency
    ),
    NOW()
  )
  FROM unnest(
    ARRAY[v_contract.organization_id, v_contract.provider_organization_id]
  ) recipient;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS booking_recovery_notification_events
  ON booking_recovery_events;
CREATE TRIGGER booking_recovery_notification_events
  AFTER INSERT ON booking_recovery_events
  FOR EACH ROW EXECUTE FUNCTION queue_booking_recovery_notification();

CREATE OR REPLACE FUNCTION claim_booking_domain_notifications(
  p_worker_id TEXT,
  p_now TIMESTAMPTZ,
  p_lease_seconds INTEGER DEFAULT 60,
  p_limit INTEGER DEFAULT 50
) RETURNS SETOF booking_domain_notification_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_previous TEXT;
  v_claimed booking_domain_notification_outbox;
BEGIN
  IF length(COALESCE(p_worker_id, '')) NOT BETWEEN 8 AND 160
    OR p_now IS NULL OR p_lease_seconds NOT BETWEEN 10 AND 600
    OR p_limit NOT BETWEEN 1 AND 200
  THEN RAISE EXCEPTION 'BOOKING_NOTIFICATION_CLAIM_INVALID'; END IF;
  v_previous := current_setting('microfams.booking_notification_engine', TRUE);
  PERFORM set_config('microfams.booking_notification_engine', 'on', TRUE);
  FOR v_claimed IN
    SELECT outbox.*
    FROM booking_domain_notification_outbox AS outbox
    WHERE outbox.attempt_count < outbox.max_attempts
      AND outbox.available_at <= p_now
      AND (
        (outbox.state IN ('queued', 'retry')
          AND outbox.next_attempt_at <= p_now)
        OR (outbox.state = 'leased' AND outbox.lease_expires_at <= p_now)
      )
    ORDER BY outbox.next_attempt_at, outbox.created_at, outbox.id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  LOOP
    UPDATE booking_domain_notification_outbox AS outbox SET
      state = 'leased',
      attempt_count = outbox.attempt_count + 1,
      lease_owner = p_worker_id,
      lease_expires_at = p_now + make_interval(secs => p_lease_seconds),
      failure_code = NULL
    WHERE outbox.id = v_claimed.id
    RETURNING outbox.* INTO v_claimed;
    RETURN NEXT v_claimed;
  END LOOP;
  PERFORM set_config(
    'microfams.booking_notification_engine', COALESCE(v_previous, ''), TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION deliver_booking_domain_notification(
  p_notification_id UUID,
  p_worker_id TEXT,
  p_delivered_at TIMESTAMPTZ
) RETURNS booking_domain_notification_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_outbox booking_domain_notification_outbox;
  v_title TEXT;
  v_message TEXT;
  v_recipients INTEGER;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_outbox
  FROM booking_domain_notification_outbox
  WHERE id = p_notification_id FOR UPDATE;
  IF NOT FOUND OR v_outbox.state <> 'leased'
    OR v_outbox.lease_owner <> p_worker_id
    OR v_outbox.lease_expires_at < p_delivered_at
  THEN RAISE EXCEPTION 'BOOKING_NOTIFICATION_LEASE_INVALID'; END IF;
  v_title := CASE v_outbox.event_type
    WHEN 'payment_custody' THEN 'Booking payment secured'
    WHEN 'service_completed' THEN 'Booking service completed'
    WHEN 'dispute_deadline' THEN 'Booking dispute deadline'
    WHEN 'dispute_opened' THEN 'Booking dispute opened'
    WHEN 'evidence_requested' THEN 'Booking evidence requested'
    WHEN 'resolution_proposed' THEN 'Booking resolution proposed'
    WHEN 'resolution_approved' THEN 'Booking resolution approved'
    WHEN 'refund_state' THEN 'Booking refund updated'
    WHEN 'payout_state' THEN 'Booking payout updated'
    WHEN 'reversal' THEN 'Booking payment reversed'
    ELSE 'Booking recovery updated'
  END;
  v_message := 'Booking ' || v_outbox.booking_id::TEXT
    || ' has a ' || replace(v_outbox.event_type, '_', ' ') || ' update.';
  INSERT INTO notifications(
    user_id, organization_id, title, message, type, source_type, source_id
  )
  SELECT membership.user_id, v_outbox.recipient_organization_id,
    v_title, v_message, 'booking', 'booking_domain_event', v_outbox.id
  FROM organization_memberships AS membership
  WHERE membership.organization_id = v_outbox.recipient_organization_id
    AND membership.status = 'active'
  ON CONFLICT (user_id, source_type, source_id)
    WHERE source_type IS NOT NULL AND source_id IS NOT NULL
  DO NOTHING;
  GET DIAGNOSTICS v_recipients = ROW_COUNT;
  IF v_recipients = 0 THEN
    RAISE EXCEPTION 'BOOKING_NOTIFICATION_NO_ACTIVE_RECIPIENTS';
  END IF;
  v_previous := current_setting('microfams.booking_notification_engine', TRUE);
  PERFORM set_config('microfams.booking_notification_engine', 'on', TRUE);
  UPDATE booking_domain_notification_outbox SET
    state = 'delivered',
    delivered_at = p_delivered_at,
    lease_owner = NULL,
    lease_expires_at = NULL,
    failure_code = NULL
  WHERE id = v_outbox.id
  RETURNING * INTO v_outbox;
  PERFORM set_config(
    'microfams.booking_notification_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_outbox;
END;
$$;

CREATE OR REPLACE FUNCTION fail_booking_domain_notification(
  p_notification_id UUID,
  p_worker_id TEXT,
  p_failure_code TEXT,
  p_failed_at TIMESTAMPTZ
) RETURNS booking_domain_notification_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_outbox booking_domain_notification_outbox;
  v_previous TEXT;
BEGIN
  IF p_failure_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'BOOKING_NOTIFICATION_FAILURE_CODE_INVALID';
  END IF;
  SELECT * INTO v_outbox
  FROM booking_domain_notification_outbox
  WHERE id = p_notification_id FOR UPDATE;
  IF NOT FOUND OR v_outbox.state <> 'leased'
    OR v_outbox.lease_owner <> p_worker_id
  THEN RAISE EXCEPTION 'BOOKING_NOTIFICATION_LEASE_INVALID'; END IF;
  v_previous := current_setting('microfams.booking_notification_engine', TRUE);
  PERFORM set_config('microfams.booking_notification_engine', 'on', TRUE);
  UPDATE booking_domain_notification_outbox SET
    state = CASE
      WHEN attempt_count >= max_attempts THEN 'dead_letter'
      ELSE 'retry'
    END,
    next_attempt_at = p_failed_at + make_interval(
      secs => LEAST(
        3600,
        30 * power(2, LEAST(GREATEST(attempt_count - 1, 0), 7))::INTEGER
      )
    ),
    lease_owner = NULL,
    lease_expires_at = NULL,
    failure_code = p_failure_code,
    dead_lettered_at = CASE
      WHEN attempt_count >= max_attempts THEN p_failed_at
      ELSE NULL
    END
  WHERE id = v_outbox.id
  RETURNING * INTO v_outbox;
  PERFORM set_config(
    'microfams.booking_notification_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_outbox;
END;
$$;

ALTER TABLE booking_domain_notification_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_domain_notification_outbox FROM PUBLIC, anon, authenticated;
GRANT SELECT ON booking_domain_notification_outbox TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_domain_notification_outbox
  FROM service_role;

REVOKE ALL ON FUNCTION enqueue_booking_domain_notification(
  UUID, UUID, UUID, UUID, TEXT, TEXT, JSONB, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION claim_booking_domain_notifications(
  TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_booking_domain_notifications(
  TEXT, TIMESTAMPTZ, INTEGER, INTEGER
) TO service_role;
REVOKE ALL ON FUNCTION deliver_booking_domain_notification(
  UUID, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION deliver_booking_domain_notification(
  UUID, TEXT, TIMESTAMPTZ
) TO service_role;
REVOKE ALL ON FUNCTION fail_booking_domain_notification(
  UUID, TEXT, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION fail_booking_domain_notification(
  UUID, TEXT, TEXT, TIMESTAMPTZ
) TO service_role;
