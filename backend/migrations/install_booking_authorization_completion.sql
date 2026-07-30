-- BS-10B: complete organization-scoped payout and dispute approval authorization.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION authorize_booking_payout_resource(
  p_organization_id UUID,
  p_actor_id UUID,
  p_required_permission TEXT,
  p_resource_type TEXT,
  p_resource_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_related BOOLEAN := FALSE;
BEGIN
  IF p_organization_id IS NULL OR p_actor_id IS NULL
    OR p_required_permission NOT IN (
      'booking.payouts.read', 'booking.payouts.service'
    )
    OR p_resource_type NOT IN (
      'organization',
      'booking_payout_beneficiary',
      'booking_payout_change_rule',
      'booking_settlement_release',
      'booking_supplier_payout'
    )
    OR p_resource_id IS NULL
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_AUTHORIZATION_INVALID'; END IF;

  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, p_required_permission
  ) THEN RAISE EXCEPTION 'BOOKING_PAYOUT_NOT_AUTHORIZED'; END IF;

  v_related := CASE p_resource_type
    WHEN 'organization' THEN p_resource_id = p_organization_id
    WHEN 'booking_payout_beneficiary' THEN EXISTS (
      SELECT 1 FROM booking_payout_beneficiaries
      WHERE id = p_resource_id AND organization_id = p_organization_id
    )
    WHEN 'booking_payout_change_rule' THEN EXISTS (
      SELECT 1 FROM booking_payout_destination_change_rules
      WHERE id = p_resource_id AND organization_id = p_organization_id
    )
    WHEN 'booking_settlement_release' THEN EXISTS (
      SELECT 1 FROM booking_settlement_releases
      WHERE id = p_resource_id
        AND provider_organization_id = p_organization_id
    )
    WHEN 'booking_supplier_payout' THEN EXISTS (
      SELECT 1 FROM payouts
      WHERE id = p_resource_id AND organization_id = p_organization_id
        AND source_type = 'booking_settlement'
    )
    ELSE FALSE
  END;
  IF NOT v_related
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_RESOURCE_NOT_FOUND'; END IF;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION booking_authorization_resource_related(
  p_organization_id UUID,
  p_resource_type TEXT,
  p_resource_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_resource_id UUID;
BEGIN
  IF p_resource_type = 'organization' THEN
    IF COALESCE(p_resource_id, '') = '' THEN RETURN TRUE; END IF;
    IF p_resource_id !~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    THEN RETURN FALSE; END IF;
    RETURN p_resource_id::UUID = p_organization_id;
  END IF;
  IF COALESCE(p_resource_id, '') !~
    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
  THEN RETURN FALSE; END IF;
  v_resource_id := p_resource_id::UUID;

  RETURN CASE p_resource_type
    WHEN 'booking' THEN EXISTS (
      SELECT 1 FROM bookings
      WHERE id = v_resource_id
        AND p_organization_id IN (
          organization_id, provider_organization_id
        )
    )
    WHEN 'booking_dispute' THEN EXISTS (
      SELECT 1 FROM booking_disputes
      WHERE id = v_resource_id
        AND p_organization_id IN (
          organization_id, provider_organization_id
        )
    )
    WHEN 'booking_settlement' THEN EXISTS (
      SELECT 1 FROM booking_settlement_contracts
      WHERE (id = v_resource_id OR booking_id = v_resource_id)
        AND p_organization_id IN (
          organization_id, provider_organization_id
        )
    )
    WHEN 'booking_dispute_resolution_proposal' THEN EXISTS (
      SELECT 1
      FROM booking_dispute_resolution_proposals AS proposal
      JOIN booking_disputes AS dispute ON dispute.id = proposal.dispute_id
      WHERE proposal.id = v_resource_id
        AND p_organization_id NOT IN (
          dispute.organization_id, dispute.provider_organization_id
        )
    )
    WHEN 'booking_payout_beneficiary' THEN EXISTS (
      SELECT 1 FROM booking_payout_beneficiaries
      WHERE id = v_resource_id AND organization_id = p_organization_id
    )
    WHEN 'booking_payout_change_rule' THEN EXISTS (
      SELECT 1 FROM booking_payout_destination_change_rules
      WHERE id = v_resource_id AND organization_id = p_organization_id
    )
    WHEN 'booking_settlement_release' THEN EXISTS (
      SELECT 1 FROM booking_settlement_releases
      WHERE id = v_resource_id
        AND provider_organization_id = p_organization_id
    )
    WHEN 'booking_supplier_payout' THEN EXISTS (
      SELECT 1 FROM payouts
      WHERE id = v_resource_id AND organization_id = p_organization_id
        AND source_type = 'booking_settlement'
    )
    ELSE FALSE
  END;
END;
$$;

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
  ) AND booking_authorization_resource_related(
    p_organization_id, p_resource_type, p_resource_id
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

CREATE OR REPLACE FUNCTION read_booking_payout_beneficiaries(
  p_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT has_booking_permission(
    p_organization_id, p_actor_id, 'booking.payouts.read'
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

CREATE OR REPLACE FUNCTION read_booking_supplier_payout(
  p_payout_id UUID,
  p_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result JSONB;
BEGIN
  PERFORM authorize_booking_payout_resource(
    p_organization_id, p_actor_id, 'booking.payouts.read',
    'booking_supplier_payout', p_payout_id
  );
  SELECT jsonb_build_object(
    'id', payout.id,
    'internal_reference', payout.internal_reference,
    'state', payout.state,
    'amount_minor', payout.amount_minor,
    'currency', payout.currency,
    'provider_name', payout.provider_name,
    'provider_environment', payout.provider_environment,
    'provider_reference', payout.provider_reference,
    'destination_masked', payout.beneficiary_masked,
    'settlement_release_id', payout.booking_settlement_release_id,
    'item_state', item.state,
    'failure_code', payout.failure_code,
    'failure_reason', payout.failure_reason,
    'correlation_id', payout.correlation_id,
    'created_at', payout.created_at,
    'updated_at', payout.updated_at,
    'terminal_at', payout.terminal_at
  ) INTO v_result
  FROM payouts AS payout
  LEFT JOIN booking_supplier_payout_items AS item
    ON item.payout_id = payout.id
  WHERE payout.id = p_payout_id
    AND payout.organization_id = p_organization_id
    AND payout.source_type = 'booking_settlement';
  IF v_result IS NULL
  THEN RAISE EXCEPTION 'BOOKING_PAYOUT_RESOURCE_NOT_FOUND'; END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION decide_booking_dispute_resolution_authorized(
  p_proposal_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dispute booking_disputes;
BEGIN
  IF p_proposal_id IS NULL OR p_acting_organization_id IS NULL
    OR p_actor_id IS NULL
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_DECISION_INVALID'; END IF;
  SELECT dispute.* INTO v_dispute
  FROM booking_dispute_resolution_proposals AS proposal
  JOIN booking_disputes AS dispute ON dispute.id = proposal.dispute_id
  WHERE proposal.id = p_proposal_id;
  IF NOT FOUND
  THEN RAISE EXCEPTION 'BOOKING_DISPUTE_RESOLUTION_NOT_FOUND'; END IF;
  IF NOT has_booking_permission(
    p_acting_organization_id, p_actor_id, 'booking.disputes.approve'
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_NOT_AUTHORIZED'; END IF;
  IF p_acting_organization_id IN (
    v_dispute.organization_id, v_dispute.provider_organization_id
  ) THEN RAISE EXCEPTION 'BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT'; END IF;
  RETURN decide_booking_dispute_resolution(
    p_proposal_id, p_actor_id, p_approve, p_reason,
    p_idempotency_key, p_correlation_id
  );
END;
$$;

REVOKE ALL ON FUNCTION authorize_booking_payout_resource(
  UUID, UUID, TEXT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION read_booking_supplier_payout(
  UUID, UUID, UUID
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_booking_dispute_resolution_authorized(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION booking_authorization_resource_related(
  UUID, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION authorize_booking_payout_resource(
  UUID, UUID, TEXT, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION read_booking_supplier_payout(
  UUID, UUID, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION decide_booking_dispute_resolution_authorized(
  UUID, UUID, UUID, BOOLEAN, TEXT, TEXT, UUID
) TO service_role;
