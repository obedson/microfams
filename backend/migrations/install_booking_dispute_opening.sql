-- BS-06: tenant-isolated booking dispute opening, evidence, and read models.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS booking_disputes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  settlement_contract_id UUID NOT NULL REFERENCES booking_settlement_contracts(id),
  booking_id UUID NOT NULL REFERENCES bookings(id),
  opened_by_organization_id UUID NOT NULL REFERENCES organizations(id),
  opened_by UUID NOT NULL REFERENCES users(id),
  opened_on_behalf BOOLEAN NOT NULL DEFAULT FALSE,
  reason_code TEXT NOT NULL CHECK (reason_code IN (
    'property_unavailable', 'property_misrepresented', 'supplier_no_show',
    'access_denied', 'unsafe_facilities', 'unusable_facilities',
    'service_incomplete', 'incorrect_amount', 'duplicate_charge',
    'agreed_cancellation_not_honoured', 'other'
  )),
  narrative TEXT NOT NULL CHECK (length(btrim(narrative)) BETWEEN 20 AND 2000),
  requested_remedy TEXT NOT NULL CHECK (requested_remedy IN (
    'refund', 'supplier_release', 'split', 'correction'
  )),
  contested_amount_minor BIGINT NOT NULL CHECK (contested_amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'opened' CHECK (state IN (
    'opened', 'evidence_collection', 'under_review', 'resolution_proposed',
    'resolved_customer', 'resolved_supplier', 'resolved_split', 'withdrawn', 'closed'
  )),
  response_deadline_at TIMESTAMPTZ NOT NULL,
  dispute_deadline_at TIMESTAMPTZ,
  rule_snapshot JSONB NOT NULL CHECK (jsonb_typeof(rule_snapshot) = 'object'),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (settlement_contract_id, id),
  CHECK (organization_id <> provider_organization_id),
  CHECK (opened_by_organization_id = organization_id),
  CHECK (reason_code <> 'other' OR length(btrim(narrative)) >= 40),
  CHECK ((state IN ('resolved_customer', 'resolved_supplier', 'resolved_split', 'closed'))
    = (resolved_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_booking_disputes_customer
  ON booking_disputes(organization_id, state, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_disputes_provider
  ON booking_disputes(provider_organization_id, state, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_disputes_booking
  ON booking_disputes(booking_id, opened_at DESC);

CREATE TABLE IF NOT EXISTS booking_dispute_evidence (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  submitted_by_organization_id UUID NOT NULL REFERENCES organizations(id),
  submitted_by UUID NOT NULL REFERENCES users(id),
  evidence_type TEXT NOT NULL CHECK (evidence_type IN (
    'statement', 'photo', 'document', 'message'
  )),
  body TEXT CHECK (body IS NULL OR length(btrim(body)) BETWEEN 2 AND 4000),
  storage_object_key TEXT CHECK (
    storage_object_key IS NULL OR length(storage_object_key) BETWEEN 8 AND 1024
  ),
  media_type TEXT CHECK (media_type IS NULL OR length(media_type) BETWEEN 3 AND 160),
  sha256 VARCHAR(64) CHECK (sha256 IS NULL OR sha256 ~ '^[a-f0-9]{64}$'),
  malware_scan_status TEXT NOT NULL DEFAULT 'not_applicable' CHECK (
    malware_scan_status IN ('not_applicable', 'pending', 'clean', 'rejected')
  ),
  visibility TEXT NOT NULL DEFAULT 'both' CHECK (
    visibility IN ('both', 'customer', 'provider', 'reviewer')
  ),
  supersedes_evidence_id UUID REFERENCES booking_dispute_evidence(id),
  retention_until TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 years'),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (dispute_id, submitted_by_organization_id, idempotency_key),
  CHECK (retention_until > created_at),
  CHECK (organization_id <> provider_organization_id),
  CHECK (
    (evidence_type IN ('statement', 'message')
      AND body IS NOT NULL
      AND storage_object_key IS NULL AND media_type IS NULL AND sha256 IS NULL
      AND malware_scan_status = 'not_applicable')
    OR
    (evidence_type IN ('photo', 'document')
      AND storage_object_key IS NOT NULL AND media_type IS NOT NULL AND sha256 IS NOT NULL
      AND malware_scan_status IN ('pending', 'clean', 'rejected'))
  )
);

CREATE INDEX IF NOT EXISTS idx_booking_dispute_evidence_timeline
  ON booking_dispute_evidence(dispute_id, created_at, id);

CREATE TABLE IF NOT EXISTS booking_dispute_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  provider_organization_id UUID NOT NULL REFERENCES organizations(id),
  dispute_id UUID NOT NULL REFERENCES booking_disputes(id),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'opened', 'evidence_added', 'state_changed', 'resolution_proposed',
    'resolved', 'withdrawn', 'closed'
  )),
  actor_organization_id UUID REFERENCES organizations(id),
  actor_id UUID REFERENCES users(id),
  from_state TEXT,
  to_state TEXT,
  public_payload JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(public_payload) = 'object'),
  correlation_id UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_booking_dispute_events_timeline
  ON booking_dispute_events(dispute_id, occurred_at, id);

CREATE OR REPLACE FUNCTION protect_booking_dispute_records() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.booking_dispute_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'Booking dispute records can only be changed by the dispute engine';
END;
$$;

CREATE OR REPLACE FUNCTION protect_booking_dispute_history() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Booking dispute history is append-only';
END;
$$;

DROP TRIGGER IF EXISTS booking_disputes_engine_only ON booking_disputes;
CREATE TRIGGER booking_disputes_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON booking_disputes
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_records();
DROP TRIGGER IF EXISTS booking_dispute_evidence_engine_only ON booking_dispute_evidence;
CREATE TRIGGER booking_dispute_evidence_engine_only
  BEFORE INSERT ON booking_dispute_evidence
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_records();
DROP TRIGGER IF EXISTS booking_dispute_evidence_append_only ON booking_dispute_evidence;
CREATE TRIGGER booking_dispute_evidence_append_only
  BEFORE UPDATE OR DELETE ON booking_dispute_evidence
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_history();
DROP TRIGGER IF EXISTS booking_dispute_events_engine_only ON booking_dispute_events;
CREATE TRIGGER booking_dispute_events_engine_only
  BEFORE INSERT ON booking_dispute_events
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_records();
DROP TRIGGER IF EXISTS booking_dispute_events_append_only ON booking_dispute_events;
CREATE TRIGGER booking_dispute_events_append_only
  BEFORE UPDATE OR DELETE ON booking_dispute_events
  FOR EACH ROW EXECUTE FUNCTION protect_booking_dispute_history();

CREATE OR REPLACE FUNCTION open_booking_dispute(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_reason_code TEXT,
  p_narrative TEXT,
  p_requested_remedy TEXT,
  p_contested_amount_minor BIGINT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_booking bookings;
  v_payment payments;
  v_existing booking_disputes;
  v_dispute booking_disputes;
  v_hash TEXT;
  v_previous_dispute TEXT;
  v_previous_settlement TEXT;
  v_refunded BIGINT;
  v_released BIGINT;
  v_contested BIGINT;
  v_available BIGINT;
  v_support BOOLEAN;
BEGIN
  IF p_booking_id IS NULL OR p_acting_organization_id IS NULL OR p_actor_id IS NULL
    OR p_correlation_id IS NULL
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR p_reason_code NOT IN (
      'property_unavailable', 'property_misrepresented', 'supplier_no_show',
      'access_denied', 'unsafe_facilities', 'unusable_facilities',
      'service_incomplete', 'incorrect_amount', 'duplicate_charge',
      'agreed_cancellation_not_honoured', 'other'
    )
    OR length(btrim(COALESCE(p_narrative, ''))) NOT BETWEEN 20 AND 2000
    OR (p_reason_code = 'other' AND length(btrim(p_narrative)) < 40)
    OR p_requested_remedy NOT IN ('refund', 'supplier_release', 'split', 'correction')
    OR COALESCE(p_contested_amount_minor, 0) <= 0
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_REQUEST_INVALID'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    p_booking_id, p_acting_organization_id, p_actor_id, p_reason_code,
    btrim(p_narrative), p_requested_remedy, p_contested_amount_minor
  ), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_existing FROM booking_disputes
  WHERE organization_id = p_acting_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF NOT (
      has_booking_permission(
        p_acting_organization_id, p_actor_id, 'booking.disputes.open'
      )
      OR is_active_platform_administrator(p_actor_id)
    ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'dispute_id', v_existing.id, 'booking_id', v_existing.booking_id,
      'state', v_existing.state, 'contested_amount_minor',
      v_existing.contested_amount_minor, 'currency', v_existing.currency,
      'idempotency_replay', TRUE
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('booking-dispute:' || p_booking_id::TEXT, 0));
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_SETTLEMENT_NOT_FOUND'; END IF;
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  SELECT * INTO v_payment FROM payments WHERE id = v_contract.payment_id FOR UPDATE;

  IF p_acting_organization_id <> v_contract.organization_id
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  v_support := is_active_platform_administrator(p_actor_id);
  IF NOT v_support
    AND NOT has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.disputes.open'
    )
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF v_payment.state NOT IN ('succeeded', 'partially_refunded')
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_PAYMENT_NOT_ELIGIBLE'; END IF;
  IF v_contract.state IN ('funding', 'refunded', 'reversed', 'settled')
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_SETTLEMENT_NOT_ELIGIBLE'; END IF;
  IF v_contract.completed_at IS NOT NULL
    AND (v_contract.dispute_deadline_at IS NULL OR NOW() > v_contract.dispute_deadline_at)
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_WINDOW_CLOSED'; END IF;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_refunded
  FROM payment_refunds
  WHERE payment_id = v_payment.id
    AND state IN ('created', 'submitted', 'processing', 'succeeded');
  SELECT COALESCE(sum(amount_minor), 0) INTO v_released
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type IN ('supplier', 'platform_fee') AND state = 'final';
  SELECT COALESCE(sum(amount_minor), 0) INTO v_contested
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id
    AND allocation_type = 'contested' AND state IN ('reserved', 'final');
  v_available := v_contract.gross_amount_minor - v_refunded - v_released - v_contested;
  IF p_contested_amount_minor > v_available
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_AMOUNT_EXCEEDS_AVAILABLE'; END IF;

  v_previous_dispute := current_setting('microfams.booking_dispute_engine', TRUE);
  v_previous_settlement := current_setting('microfams.booking_settlement_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  PERFORM set_config('microfams.booking_settlement_engine', 'on', TRUE);

  INSERT INTO booking_disputes(
    organization_id, provider_organization_id, settlement_contract_id, booking_id,
    opened_by_organization_id, opened_by, opened_on_behalf, reason_code, narrative,
    requested_remedy, contested_amount_minor, currency, response_deadline_at,
    dispute_deadline_at, rule_snapshot, idempotency_key, request_hash, correlation_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    v_contract.booking_id, p_acting_organization_id, p_actor_id, v_support,
    p_reason_code, btrim(p_narrative), p_requested_remedy,
    p_contested_amount_minor, v_contract.currency, NOW() + INTERVAL '72 hours',
    v_contract.dispute_deadline_at,
    jsonb_build_object(
      'policy_version', 'BS-2026-07-28',
      'freeze_scope', 'contested_amount_only',
      'response_window_hours', 72,
      'settlement_rule_id', v_contract.settlement_rule_id
    ),
    p_idempotency_key, v_hash, p_correlation_id
  ) RETURNING * INTO v_dispute;

  INSERT INTO booking_settlement_allocations(
    organization_id, provider_organization_id, settlement_contract_id,
    allocation_type, state, amount_minor, currency, source_type, source_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'contested', 'reserved', p_contested_amount_minor, v_contract.currency,
    'booking_dispute', v_dispute.id
  );
  INSERT INTO booking_settlement_holds(
    organization_id, provider_organization_id, settlement_contract_id,
    hold_type, amount_minor, currency, source_type, source_id, reason_code
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_contract.id,
    'dispute', p_contested_amount_minor, v_contract.currency,
    'booking_dispute', v_dispute.id::TEXT, p_reason_code
  );
  UPDATE booking_settlement_contracts
  SET state = 'disputed', updated_at = NOW()
  WHERE id = v_contract.id;

  INSERT INTO booking_dispute_events(
    organization_id, provider_organization_id, dispute_id, event_type,
    actor_organization_id, actor_id, to_state, public_payload, correlation_id
  ) VALUES (
    v_contract.organization_id, v_contract.provider_organization_id, v_dispute.id,
    'opened', p_acting_organization_id, p_actor_id, 'opened',
    jsonb_build_object(
      'reason_code', p_reason_code, 'requested_remedy', p_requested_remedy,
      'contested_amount_minor', p_contested_amount_minor,
      'currency', v_contract.currency, 'opened_on_behalf', v_support
    ),
    p_correlation_id
  );

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_contract.organization_id, p_actor_id, 'booking.dispute.opened',
    'booking_dispute', v_dispute.id::TEXT,
    jsonb_build_object('booking_id', v_contract.booking_id, 'correlation_id', p_correlation_id)
  );
  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_contract.provider_organization_id, p_actor_id, 'booking.dispute.opened',
    'booking_dispute', v_dispute.id::TEXT,
    jsonb_build_object('booking_id', v_contract.booking_id, 'correlation_id', p_correlation_id)
  );

  PERFORM set_config(
    'microfams.booking_dispute_engine', COALESCE(v_previous_dispute, ''), TRUE
  );
  PERFORM set_config(
    'microfams.booking_settlement_engine', COALESCE(v_previous_settlement, ''), TRUE
  );
  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id, 'booking_id', v_dispute.booking_id,
    'state', v_dispute.state, 'contested_amount_minor',
    v_dispute.contested_amount_minor, 'currency', v_dispute.currency,
    'response_deadline_at', v_dispute.response_deadline_at,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION add_booking_dispute_evidence(
  p_dispute_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_evidence_type TEXT,
  p_body TEXT,
  p_storage_object_key TEXT,
  p_media_type TEXT,
  p_sha256 TEXT,
  p_malware_scan_status TEXT,
  p_visibility TEXT,
  p_supersedes_evidence_id UUID,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_dispute booking_disputes;
  v_existing booking_dispute_evidence;
  v_evidence booking_dispute_evidence;
  v_hash TEXT;
  v_previous TEXT;
  v_authorized BOOLEAN;
BEGIN
  IF p_dispute_id IS NULL OR p_acting_organization_id IS NULL OR p_actor_id IS NULL
    OR p_correlation_id IS NULL
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
    OR p_evidence_type NOT IN ('statement', 'photo', 'document', 'message')
    OR p_visibility NOT IN ('both', 'customer', 'provider', 'reviewer')
    OR (
      p_evidence_type IN ('statement', 'message')
      AND (
        length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 2 AND 4000
        OR p_storage_object_key IS NOT NULL OR p_media_type IS NOT NULL OR p_sha256 IS NOT NULL
        OR p_malware_scan_status <> 'not_applicable'
      )
    )
    OR (
      p_evidence_type IN ('photo', 'document')
      AND (
        length(COALESCE(p_storage_object_key, '')) NOT BETWEEN 8 AND 1024
        OR length(COALESCE(p_media_type, '')) NOT BETWEEN 3 AND 160
        OR COALESCE(p_sha256, '') !~ '^[a-f0-9]{64}$'
        OR p_malware_scan_status NOT IN ('pending', 'clean', 'rejected')
      )
    )
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_EVIDENCE_INVALID'; END IF;

  SELECT * INTO v_dispute FROM booking_disputes WHERE id = p_dispute_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_FOUND'; END IF;
  v_authorized := (
    p_acting_organization_id IN (
      v_dispute.organization_id, v_dispute.provider_organization_id
    )
    AND has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.disputes.evidence'
    )
  ) OR is_active_platform_administrator(p_actor_id);
  IF NOT v_authorized THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF p_acting_organization_id NOT IN (
    v_dispute.organization_id, v_dispute.provider_organization_id
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_TENANT_SCOPE_INVALID'; END IF;
  IF v_dispute.state IN (
    'resolved_customer', 'resolved_supplier', 'resolved_split', 'withdrawn', 'closed'
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_EVIDENCE_WINDOW_CLOSED'; END IF;
  IF p_supersedes_evidence_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM booking_dispute_evidence
    WHERE id = p_supersedes_evidence_id AND dispute_id = p_dispute_id
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_EVIDENCE_VERSION_INVALID'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    p_dispute_id, p_acting_organization_id, p_actor_id, p_evidence_type,
    COALESCE(btrim(p_body), ''), COALESCE(p_storage_object_key, ''),
    COALESCE(p_media_type, ''), COALESCE(p_sha256, ''), p_malware_scan_status,
    p_visibility, COALESCE(p_supersedes_evidence_id::TEXT, '')
  ), 'UTF8'), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM booking_dispute_evidence
  WHERE dispute_id = p_dispute_id
    AND submitted_by_organization_id = p_acting_organization_id
    AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash
    THEN RAISE EXCEPTION 'IDEMPOTENCY_REPLAY_CONFLICT'; END IF;
    RETURN jsonb_build_object(
      'evidence_id', v_existing.id, 'dispute_id', v_existing.dispute_id,
      'malware_scan_status', v_existing.malware_scan_status,
      'idempotency_replay', TRUE
    );
  END IF;

  v_previous := current_setting('microfams.booking_dispute_engine', TRUE);
  PERFORM set_config('microfams.booking_dispute_engine', 'on', TRUE);
  INSERT INTO booking_dispute_evidence(
    organization_id, provider_organization_id, dispute_id,
    submitted_by_organization_id, submitted_by, evidence_type, body,
    storage_object_key, media_type, sha256, malware_scan_status, visibility,
    supersedes_evidence_id, idempotency_key, request_hash, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
    p_acting_organization_id, p_actor_id, p_evidence_type, NULLIF(btrim(p_body), ''),
    p_storage_object_key, p_media_type, p_sha256, p_malware_scan_status, p_visibility,
    p_supersedes_evidence_id, p_idempotency_key, v_hash, p_correlation_id
  ) RETURNING * INTO v_evidence;
  INSERT INTO booking_dispute_events(
    organization_id, provider_organization_id, dispute_id, event_type,
    actor_organization_id, actor_id, to_state, public_payload, correlation_id
  ) VALUES (
    v_dispute.organization_id, v_dispute.provider_organization_id, v_dispute.id,
    'evidence_added', p_acting_organization_id, p_actor_id, v_dispute.state,
    jsonb_build_object(
      'evidence_id', v_evidence.id, 'evidence_type', v_evidence.evidence_type,
      'malware_scan_status', v_evidence.malware_scan_status,
      'has_attachment', v_evidence.storage_object_key IS NOT NULL
    ),
    p_correlation_id
  );
  PERFORM set_config('microfams.booking_dispute_engine', COALESCE(v_previous, ''), TRUE);
  RETURN jsonb_build_object(
    'evidence_id', v_evidence.id, 'dispute_id', v_evidence.dispute_id,
    'malware_scan_status', v_evidence.malware_scan_status,
    'idempotency_replay', FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION read_booking_dispute_timeline(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
BEGIN
  SELECT * INTO v_contract FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_FOUND'; END IF;
  IF p_acting_organization_id NOT IN (
      v_contract.organization_id, v_contract.provider_organization_id
    )
    OR NOT (
      has_booking_permission(
        p_acting_organization_id, p_actor_id, 'booking.disputes.read'
      )
      OR is_active_platform_administrator(p_actor_id)
    )
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;

  RETURN jsonb_build_object(
    'booking_id', p_booking_id,
    'disputes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', dispute.id,
        'state', dispute.state,
        'reason_code', dispute.reason_code,
        'narrative', dispute.narrative,
        'requested_remedy', dispute.requested_remedy,
        'contested_amount_minor', dispute.contested_amount_minor,
        'currency', dispute.currency,
        'opened_on_behalf', dispute.opened_on_behalf,
        'opened_at', dispute.opened_at,
        'response_deadline_at', dispute.response_deadline_at,
        'dispute_deadline_at', dispute.dispute_deadline_at,
        'evidence', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', evidence.id,
            'submitted_by_organization_id', evidence.submitted_by_organization_id,
            'evidence_type', evidence.evidence_type,
            'body', evidence.body,
            'media_type', evidence.media_type,
            'malware_scan_status', evidence.malware_scan_status,
            'has_attachment', evidence.storage_object_key IS NOT NULL
              AND evidence.malware_scan_status = 'clean',
            'visibility', evidence.visibility,
            'supersedes_evidence_id', evidence.supersedes_evidence_id,
            'created_at', evidence.created_at
          ) ORDER BY evidence.created_at, evidence.id)
          FROM booking_dispute_evidence AS evidence
          WHERE evidence.dispute_id = dispute.id
            AND (
              evidence.visibility = 'both'
              OR (evidence.visibility = 'customer'
                AND p_acting_organization_id = dispute.organization_id)
              OR (evidence.visibility = 'provider'
                AND p_acting_organization_id = dispute.provider_organization_id)
              OR (evidence.visibility = 'reviewer'
                AND is_active_platform_administrator(p_actor_id))
            )
        ), '[]'::JSONB),
        'events', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', event.id,
            'event_type', event.event_type,
            'actor_organization_id', event.actor_organization_id,
            'from_state', event.from_state,
            'to_state', event.to_state,
            'payload', event.public_payload,
            'correlation_id', event.correlation_id,
            'occurred_at', event.occurred_at
          ) ORDER BY event.occurred_at, event.id)
          FROM booking_dispute_events AS event
          WHERE event.dispute_id = dispute.id
        ), '[]'::JSONB)
      ) ORDER BY dispute.opened_at, dispute.id)
      FROM booking_disputes AS dispute
      WHERE dispute.booking_id = p_booking_id
    ), '[]'::JSONB)
  );
END;
$$;

UPDATE organization_memberships SET permissions = ARRAY(
  SELECT DISTINCT permission FROM unnest(permissions || ARRAY[
    'booking.disputes.open', 'booking.disputes.read', 'booking.disputes.evidence'
  ]) permission
) WHERE role = 'owner';

ALTER TABLE booking_disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_dispute_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON booking_disputes, booking_dispute_evidence,
  booking_dispute_events FROM anon, authenticated;
GRANT SELECT ON booking_disputes, booking_dispute_evidence,
  booking_dispute_events TO service_role;
REVOKE INSERT, UPDATE, DELETE ON booking_disputes, booking_dispute_evidence,
  booking_dispute_events FROM service_role;

REVOKE ALL ON FUNCTION protect_booking_dispute_records()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION protect_booking_dispute_history()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION open_booking_dispute(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, BIGINT, TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION open_booking_dispute(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, BIGINT, TEXT, UUID
) TO service_role;
REVOKE ALL ON FUNCTION add_booking_dispute_evidence(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION add_booking_dispute_evidence(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID
) TO service_role;
REVOKE ALL ON FUNCTION read_booking_dispute_timeline(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_booking_dispute_timeline(UUID, UUID, UUID) TO service_role;
