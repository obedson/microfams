DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  wallet_id UUID;
  reservation fund_reservations;
  withdrawal_id UUID;
  payout payouts;
  replay payouts;
  provider_event provider_events;
  provider_event_replay provider_events;
  before_failure_minor BIGINT;
BEGIN
  SELECT id INTO wallet_id FROM user_wallets
  WHERE organization_id = tenant_id AND user_id = actor_id;

  PERFORM atomic_wallet_credit(wallet_id, 3000.00, 'COLLECTION', 'schema-payout-funding');

  reservation := reserve_wallet_funds(
    wallet_id, 101000, 'schema-payout-success', 'schema-payout-key-success',
    '00000000-0000-4000-8000-000000009001', actor_id, NOW() + INTERVAL '10 minutes'
  );
  reservation := consume_wallet_reservation(reservation.id, actor_id);
  INSERT INTO withdrawal_requests(
    user_id, organization_id, wallet_id, reservation_id, amount, fee_amount,
    amount_minor, fee_amount_minor, account_number, bank_code, account_name,
    status, internal_ref
  ) VALUES (
    actor_id, tenant_id, wallet_id, reservation.id, 1000.00, 10.00, 100000, 1000,
    '0000000000', '044', 'Synthetic Beneficiary', 'PENDING', 'WD-schema-payout-success'
  ) RETURNING id INTO withdrawal_id;

  payout := create_wallet_payout(
    withdrawal_id, 'deterministic', 'deterministic', repeat('a', 64), '******0000',
    '00000000-0000-4000-8000-000000009001', actor_id
  );
  replay := create_wallet_payout(
    withdrawal_id, 'deterministic', 'deterministic', repeat('a', 64), '******0000',
    '00000000-0000-4000-8000-000000009001', actor_id
  );
  IF payout.id <> replay.id OR payout.state <> 'reserved' THEN
    RAISE EXCEPTION 'payout creation replay was not idempotent';
  END IF;
  BEGIN
    UPDATE payouts SET state = 'succeeded' WHERE id = payout.id;
    RAISE EXCEPTION 'payout allowed direct state mutation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'payout allowed direct state mutation' THEN RAISE; END IF;
  END;

  payout := mark_payout_submitted(payout.id, repeat('b', 64), 'DET-success-1', TRUE);
  IF payout.state <> 'processing' THEN RAISE EXCEPTION 'unknown submission did not remain recoverable'; END IF;
  payout := succeed_wallet_payout(payout.id, 'DET-success-1', 100000, 'NGN');
  replay := succeed_wallet_payout(payout.id, 'DET-success-1', 100000, 'NGN');
  IF payout.state <> 'succeeded' OR replay.success_journal_entry_id <> payout.success_journal_entry_id
    OR NOT EXISTS (SELECT 1 FROM withdrawal_requests WHERE id = withdrawal_id AND status = 'SUCCESS') THEN
    RAISE EXCEPTION 'payout success was not atomic and idempotent';
  END IF;
  BEGIN
    PERFORM succeed_wallet_payout(payout.id, 'DET-success-1', 100001, 'NGN');
    RAISE EXCEPTION 'payout accepted a changed success amount';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'payout accepted a changed success amount' THEN RAISE; END IF;
  END;

  provider_event := record_provider_event(
    tenant_id, payout.id, 'deterministic', 'deterministic', 'event-success-1',
    'payout.succeeded', repeat('c', 64),
    jsonb_build_object('internalReference', payout.internal_reference, 'amountMinor', 100000, 'currency', 'NGN'), NOW()
  );
  provider_event_replay := record_provider_event(
    tenant_id, payout.id, 'deterministic', 'deterministic', 'event-success-1',
    'payout.succeeded', repeat('c', 64), '{}'::JSONB, NOW()
  );
  IF provider_event.id <> provider_event_replay.id THEN RAISE EXCEPTION 'provider event replay duplicated'; END IF;
  provider_event := finish_provider_event(provider_event.id, 'processed', NULL);
  provider_event_replay := finish_provider_event(provider_event.id, 'processed', NULL);
  IF provider_event_replay.processing_state <> 'processed' THEN RAISE EXCEPTION 'provider event completion is not idempotent'; END IF;

  before_failure_minor := (wallet_balance_summary(wallet_id)->>'ledgerBalanceMinor')::BIGINT;
  reservation := reserve_wallet_funds(
    wallet_id, 100500, 'schema-payout-failure', 'schema-payout-key-failure',
    '00000000-0000-4000-8000-000000009002', actor_id, NOW() + INTERVAL '10 minutes'
  );
  reservation := consume_wallet_reservation(reservation.id, actor_id);
  INSERT INTO withdrawal_requests(
    user_id, organization_id, wallet_id, reservation_id, amount, fee_amount,
    amount_minor, fee_amount_minor, account_number, bank_code, account_name,
    status, internal_ref
  ) VALUES (
    actor_id, tenant_id, wallet_id, reservation.id, 1000.00, 5.00, 100000, 500,
    '0000000000', '044', 'Synthetic Beneficiary', 'PENDING', 'WD-schema-payout-failure'
  ) RETURNING id INTO withdrawal_id;
  payout := create_wallet_payout(
    withdrawal_id, 'deterministic', 'deterministic', repeat('d', 64), '******0000',
    '00000000-0000-4000-8000-000000009002', actor_id
  );
  payout := mark_payout_submitted(payout.id, repeat('e', 64), 'DET-failure-1', FALSE);
  payout := fail_wallet_payout(payout.id, 'DECLINED', 'Synthetic provider decline');
  replay := fail_wallet_payout(payout.id, 'DECLINED', 'Synthetic provider decline');
  IF payout.state <> 'failed' OR replay.id <> payout.id
    OR (wallet_balance_summary(wallet_id)->>'ledgerBalanceMinor')::BIGINT <> before_failure_minor
    OR NOT EXISTS (SELECT 1 FROM withdrawal_requests WHERE id = withdrawal_id AND status = 'FAILED') THEN
    RAISE EXCEPTION 'failed payout did not restore the exact consumed reservation';
  END IF;
END $$;

GRANT SELECT ON payouts, payout_attempts, provider_events TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM payouts) <> 2 OR (SELECT count(*) FROM provider_events) <> 1 THEN
    RAISE EXCEPTION 'tenant cannot read its payout records';
  END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM payouts) <> 0 OR (SELECT count(*) FROM provider_events) <> 0 THEN
    RAISE EXCEPTION 'payout records leaked across tenants';
  END IF;
END $$;
RESET ROLE;
