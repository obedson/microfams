DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  payment payments;
  replay payments;
  refund payment_refunds;
  refund_replay payment_refunds;
  event payment_provider_events;
  event_replay payment_provider_events;
  settlement settlements;
  source_id UUID := gen_random_uuid();
BEGIN
  payment := create_payment_intent(
    tenant_id, 'booking', source_id, actor_id, 'PAY-schema-success-001',
    'schema-payment-success-key', 'deterministic', 'deterministic', 'NGN', 100000,
    '00000000-0000-4000-8000-000000009101', actor_id
  );
  replay := create_payment_intent(
    tenant_id, 'booking', source_id, actor_id, 'PAY-schema-success-001',
    'schema-payment-success-key', 'deterministic', 'deterministic', 'NGN', 100000,
    '00000000-0000-4000-8000-000000009101', actor_id
  );
  IF payment.id <> replay.id OR payment.state <> 'created' THEN
    RAISE EXCEPTION 'payment creation replay was not idempotent';
  END IF;
  BEGIN
    PERFORM create_payment_intent(
      tenant_id, 'booking', source_id, actor_id, 'PAY-schema-success-001',
      'schema-payment-success-key', 'deterministic', 'deterministic', 'NGN', 100001,
      '00000000-0000-4000-8000-000000009101', actor_id
    );
    RAISE EXCEPTION 'payment replay accepted changed money';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'payment replay accepted changed money' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE payments SET state = 'succeeded' WHERE id = payment.id;
    RAISE EXCEPTION 'payment allowed direct state mutation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'payment allowed direct state mutation' THEN RAISE; END IF;
  END;

  payment := mark_payment_initialized(payment.id, repeat('a', 64), 'PAY-schema-success-001',
    'requires_action', NOW() + INTERVAL '1 hour');
  payment := succeed_inbound_payment(payment.id, 'PAY-schema-success-001', 100000, 'NGN');
  replay := succeed_inbound_payment(payment.id, 'PAY-schema-success-001', 100000, 'NGN');
  IF payment.state <> 'succeeded' OR replay.success_journal_entry_id <> payment.success_journal_entry_id
    OR NOT EXISTS (
      SELECT 1 FROM journal_entries entry JOIN journal_lines line ON line.journal_entry_id = entry.id
      WHERE entry.id = payment.success_journal_entry_id
      GROUP BY entry.id HAVING sum(CASE WHEN line.side = 'debit' THEN line.amount_minor ELSE -line.amount_minor END) = 0
    ) THEN RAISE EXCEPTION 'payment success was not balanced and idempotent'; END IF;
  BEGIN
    PERFORM succeed_inbound_payment(payment.id, 'PAY-schema-success-001', 99999, 'NGN');
    RAISE EXCEPTION 'payment accepted changed confirmation money';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'payment accepted changed confirmation money' THEN RAISE; END IF;
  END;

  event := record_payment_provider_event(
    tenant_id, payment.id, 'deterministic', 'deterministic', 'payment-event-001',
    'charge.success', repeat('b', 64),
    jsonb_build_object('internalReference', payment.internal_reference, 'amountMinor', 100000, 'currency', 'NGN'), NOW()
  );
  event_replay := record_payment_provider_event(
    tenant_id, payment.id, 'deterministic', 'deterministic', 'payment-event-001',
    'charge.success', repeat('b', 64), '{}'::JSONB, NOW()
  );
  IF event.id <> event_replay.id THEN RAISE EXCEPTION 'payment event replay duplicated'; END IF;
  event := finish_payment_provider_event(event.id, 'processed', NULL);
  event_replay := finish_payment_provider_event(event.id, 'processed', NULL);
  IF event_replay.processing_state <> 'processed' THEN RAISE EXCEPTION 'payment event finish was not idempotent'; END IF;

  refund := create_payment_refund(
    payment.id, 'REF-schema-partial-001', 'schema-refund-partial-key', 40000,
    'customer_request', 'Approved partial refund', actor_id, 'approval-schema-001'
  );
  refund_replay := create_payment_refund(
    payment.id, 'REF-schema-partial-001', 'schema-refund-partial-key', 40000,
    'customer_request', 'Approved partial refund', actor_id, 'approval-schema-001'
  );
  IF refund.id <> refund_replay.id THEN RAISE EXCEPTION 'refund replay duplicated'; END IF;
  refund := apply_payment_refund_result(refund.id, 'DET-refund-001', 'processing', NULL, NULL);
  refund := apply_payment_refund_result(refund.id, 'DET-refund-001', 'succeeded', NULL, NULL);
  IF refund.state <> 'succeeded' OR (SELECT state FROM payments WHERE id = payment.id) <> 'partially_refunded'
    THEN RAISE EXCEPTION 'partial refund lifecycle failed'; END IF;
  BEGIN
    PERFORM create_payment_refund(
      payment.id, 'REF-schema-too-large', 'schema-refund-too-large', 60001,
      'customer_request', 'Invalid cumulative refund', actor_id, NULL
    );
    RAISE EXCEPTION 'refund exceeded cumulative payment amount';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'refund exceeded cumulative payment amount' THEN RAISE; END IF;
  END;

  payment := create_payment_intent(
    tenant_id, 'marketplace_order', gen_random_uuid(), actor_id, 'PAY-schema-reversal-001',
    'schema-payment-reversal-key', 'deterministic', 'deterministic', 'NGN', 75000,
    '00000000-0000-4000-8000-000000009102', actor_id
  );
  payment := mark_payment_initialized(payment.id, repeat('c', 64), 'PAY-schema-reversal-001',
    'processing', NULL);
  payment := succeed_inbound_payment(payment.id, 'PAY-schema-reversal-001', 75000, 'NGN');
  PERFORM reverse_inbound_payment(
    payment.id, 'provider-reversal-001', 'REV-schema-payment-001', 75000,
    'Provider charge reversal', NOW()
  );
  PERFORM reverse_inbound_payment(
    payment.id, 'provider-reversal-001', 'REV-schema-payment-001', 75000,
    'Provider charge reversal', NOW()
  );
  IF (SELECT count(*) FROM payment_reversals WHERE payment_id = payment.id) <> 1 THEN
    RAISE EXCEPTION 'provider reversal was not idempotent';
  END IF;

  settlement := post_provider_settlement(
    tenant_id, 'deterministic', 'deterministic', 'SET-schema-001', 'NGN',
    175000, 2500, repeat('d', 64), NOW()
  );
  IF settlement.state <> 'posted' OR settlement.net_amount_minor <> 172500
    OR NOT EXISTS (SELECT 1 FROM payment_fees WHERE settlement_id = settlement.id AND amount_minor = 2500)
    THEN RAISE EXCEPTION 'settlement fee posting failed'; END IF;
END $$;

GRANT SELECT ON payments, payment_refunds, payment_reversals, payment_provider_events, settlements TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM payments) <> 2 OR (SELECT count(*) FROM payment_provider_events) <> 1 THEN
    RAISE EXCEPTION 'tenant cannot read its payment records';
  END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM payments) <> 0 OR (SELECT count(*) FROM payment_provider_events) <> 0 THEN
    RAISE EXCEPTION 'payment records leaked across tenants';
  END IF;
END $$;
RESET ROLE;
