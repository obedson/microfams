-- BS-12A: perspective-safe booking settlement statements and finance controls.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION read_booking_settlement_statement(
  p_booking_id UUID,
  p_acting_organization_id UUID,
  p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_contract booking_settlement_contracts;
  v_payment payments;
  v_perspective TEXT;
  v_refund_reserved BIGINT := 0;
  v_refunded BIGINT := 0;
  v_contested BIGINT := 0;
  v_supplier BIGINT := 0;
  v_fee BIGINT := 0;
  v_reversed BIGINT := 0;
  v_refundable BIGINT := 0;
  v_unallocated BIGINT := 0;
  v_refund_state TEXT;
  v_dispute_state TEXT;
  v_payout_state TEXT;
  v_destination_masked TEXT;
  v_refunds JSONB := '[]'::JSONB;
  v_disputes JSONB := '[]'::JSONB;
  v_payouts JSONB := '[]'::JSONB;
  v_recoveries JSONB := '[]'::JSONB;
  v_finance_allowed BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_contract
  FROM booking_settlement_contracts
  WHERE booking_id = p_booking_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_FOUND';
  END IF;

  IF p_acting_organization_id NOT IN (
      v_contract.organization_id, v_contract.provider_organization_id
    )
    OR NOT has_booking_permission(
      p_acting_organization_id, p_actor_id, 'booking.settlements.read'
    )
  THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_NOT_AUTHORIZED';
  END IF;

  v_perspective := CASE
    WHEN p_acting_organization_id = v_contract.organization_id
      THEN 'customer'
    ELSE 'supplier'
  END;
  v_finance_allowed :=
    has_financial_permission(
      p_acting_organization_id, p_actor_id, 'financial.reconciliation.manual'
    )
    OR has_financial_permission(
      p_acting_organization_id, p_actor_id, 'financial.reconciliation.approve'
    );

  SELECT * INTO v_payment FROM payments WHERE id = v_contract.payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BOOKING_SETTLEMENT_PAYMENT_NOT_FOUND';
  END IF;

  SELECT
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'refund' AND state = 'reserved'
    ), 0),
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'refund' AND state = 'final'
    ), 0),
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'contested' AND state IN ('reserved', 'final')
    ), 0),
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'supplier' AND state = 'final'
    ), 0),
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'platform_fee' AND state = 'final'
    ), 0),
    COALESCE(sum(amount_minor) FILTER (
      WHERE allocation_type = 'reversal' AND state = 'final'
    ), 0)
  INTO
    v_refund_reserved, v_refunded, v_contested,
    v_supplier, v_fee, v_reversed
  FROM booking_settlement_allocations
  WHERE settlement_contract_id = v_contract.id;

  v_refundable := GREATEST(
    v_contract.gross_amount_minor - v_refund_reserved - v_refunded
      - v_contested - v_supplier - v_fee - v_reversed,
    0
  );
  v_unallocated := v_refundable;

  SELECT state INTO v_refund_state
  FROM payment_refunds
  WHERE payment_id = v_contract.payment_id
  ORDER BY created_at DESC, id DESC
  LIMIT 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', refund.id,
    'amount_minor', refund.amount_minor,
    'state', refund.state,
    'created_at', refund.created_at,
    'updated_at', refund.updated_at
  ) ORDER BY refund.created_at, refund.id), '[]'::JSONB)
  INTO v_refunds
  FROM payment_refunds AS refund
  WHERE refund.payment_id = v_contract.payment_id;

  SELECT state INTO v_dispute_state
  FROM booking_disputes
  WHERE settlement_contract_id = v_contract.id
  ORDER BY opened_at DESC, id DESC
  LIMIT 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', dispute.id,
    'state', dispute.state,
    'contested_amount_minor', dispute.contested_amount_minor,
    'response_deadline_at', dispute.response_deadline_at,
    'opened_at', dispute.opened_at,
    'resolved_at', dispute.resolved_at
  ) ORDER BY dispute.opened_at, dispute.id), '[]'::JSONB)
  INTO v_disputes
  FROM booking_disputes AS dispute
  WHERE dispute.settlement_contract_id = v_contract.id;

  SELECT payout.state, item.destination_masked
  INTO v_payout_state, v_destination_masked
  FROM booking_supplier_payout_items AS item
  JOIN payouts AS payout ON payout.id = item.payout_id
  WHERE item.settlement_contract_id = v_contract.id
  ORDER BY item.created_at DESC, item.id DESC
  LIMIT 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', payout.id,
    'release_id', item.settlement_release_id,
    'amount_minor', item.amount_minor,
    'state', payout.state,
    'item_state', item.state,
    'destination_masked', item.destination_masked,
    'provider', payout.provider_name,
    'provider_environment', payout.provider_environment,
    'created_at', payout.created_at,
    'updated_at', payout.updated_at
  ) ORDER BY item.created_at, item.id), '[]'::JSONB)
  INTO v_payouts
  FROM booking_supplier_payout_items AS item
  JOIN payouts AS payout ON payout.id = item.payout_id
  WHERE item.settlement_contract_id = v_contract.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', recovery.id,
    'state', recovery.state,
    'reversed_amount_minor', recovery.reversed_amount_minor,
    'recovered_amount_minor', recovery.recovered_amount_minor,
    'loss_amount_minor', recovery.loss_amount_minor,
    'created_at', recovery.created_at,
    'updated_at', recovery.updated_at
  ) ORDER BY recovery.created_at, recovery.id), '[]'::JSONB)
  INTO v_recoveries
  FROM booking_recovery_cases AS recovery
  WHERE recovery.settlement_contract_id = v_contract.id;

  RETURN jsonb_build_object(
    'booking_id', v_contract.booking_id,
    'settlement_id', v_contract.id,
    'currency', v_contract.currency,
    'perspective', v_perspective,
    'settlement_state', v_contract.state,
    'statement', CASE v_perspective
      WHEN 'customer' THEN jsonb_build_object(
        'paid_amount_minor', v_contract.gross_amount_minor,
        'refundable_amount_minor', v_refundable,
        'refund_pending_amount_minor', v_refund_reserved,
        'refunded_amount_minor', v_refunded,
        'contested_amount_minor', v_contested,
        'released_amount_minor', v_supplier + v_fee,
        'refund_state', COALESCE(v_refund_state, 'none'),
        'dispute_state', COALESCE(v_dispute_state, 'none')
      )
      ELSE jsonb_build_object(
        'gross_amount_minor', v_contract.gross_amount_minor,
        'refund_amount_minor', v_refund_reserved + v_refunded,
        'fee_calculation', jsonb_build_object(
          'amount_minor', v_fee,
          'eligibility_snapshot', v_contract.eligibility_snapshot
        ),
        'net_proceeds_minor', v_supplier,
        'dispute_hold_minor', v_contested,
        'payout_state', COALESCE(v_payout_state, 'not_created'),
        'destination_masked', v_destination_masked,
        'expected_release_at', v_contract.dispute_deadline_at
      )
    END,
    'finance_statement', CASE WHEN v_finance_allowed THEN jsonb_build_object(
      'payment', jsonb_build_object(
        'id', v_payment.id,
        'amount_minor', v_payment.amount_minor,
        'state', v_payment.state,
        'provider', v_payment.provider_name,
        'provider_environment', v_payment.provider_environment
      ),
      'escrow', jsonb_build_object(
        'funded_amount_minor', v_contract.gross_amount_minor,
        'unallocated_amount_minor', v_unallocated,
        'state', v_contract.state
      ),
      'refunds', v_refunds,
      'refund_reserved_amount_minor', v_refund_reserved,
      'refunded_amount_minor', v_refunded,
      'disputes', v_disputes,
      'contested_amount_minor', v_contested,
      'supplier_payable_minor', v_supplier,
      'platform_fee_minor', v_fee,
      'payouts', v_payouts,
      'reversed_amount_minor', v_reversed,
      'recoveries', v_recoveries,
      'control_total_minor',
        v_unallocated + v_refund_reserved + v_refunded + v_contested
          + v_supplier + v_fee + v_reversed,
      'unexplained_variance_minor',
        v_contract.gross_amount_minor - (
          v_unallocated + v_refund_reserved + v_refunded + v_contested
            + v_supplier + v_fee + v_reversed
        )
    ) ELSE NULL END,
    'completed_at', v_contract.completed_at,
    'dispute_deadline_at', v_contract.dispute_deadline_at,
    'released_at', v_contract.released_at,
    'updated_at', v_contract.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION read_booking_settlement_statement(UUID, UUID, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION read_booking_settlement_statement(UUID, UUID, UUID)
  TO service_role;
