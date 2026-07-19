DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  wallet_user_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000102';
  other_member_id CONSTANT UUID := '00000000-0000-4000-8000-000000000103';
  test_wallet_id UUID;
  peer_wallet_id UUID;
  test_group_id UUID;
  group_request_id UUID;
  group_request_replay_id UUID;
  reservation fund_reservations;
  replay fund_reservations;
  summary JSONB;
  transfer JSONB;
  expired_count INTEGER;
BEGIN
  SELECT id INTO test_wallet_id FROM user_wallets
  WHERE organization_id = tenant_id AND user_id = wallet_user_id;
  SELECT id INTO peer_wallet_id FROM user_wallets
  WHERE organization_id = tenant_id AND user_id = other_member_id;

  summary := wallet_balance_summary(test_wallet_id);
  IF summary->>'currency' <> 'NGN'
    OR (summary->>'ledgerBalanceMinor')::BIGINT <> 2400
    OR (summary->>'availableBalanceMinor')::BIGINT <> 2400
    OR (summary->>'pendingDebitsMinor')::BIGINT <> 0 THEN
    RAISE EXCEPTION 'initial minor-unit wallet summary is incorrect: %', summary;
  END IF;

  reservation := reserve_wallet_funds(
    test_wallet_id, 1000, 'withdrawal-reservation-1', 'reservation-key-0001',
    '00000000-0000-4000-8000-000000008001', actor_id, NOW() + INTERVAL '10 minutes'
  );
  replay := reserve_wallet_funds(
    test_wallet_id, 1000, 'withdrawal-reservation-1', 'reservation-key-0001',
    '00000000-0000-4000-8000-000000008001', actor_id, reservation.expires_at
  );
  IF replay.id <> reservation.id OR replay.state <> 'active' THEN
    RAISE EXCEPTION 'reservation replay was not idempotent';
  END IF;
  summary := wallet_balance_summary(test_wallet_id);
  IF (summary->>'ledgerBalanceMinor')::BIGINT <> 2400
    OR (summary->>'pendingDebitsMinor')::BIGINT <> 1000
    OR (summary->>'availableBalanceMinor')::BIGINT <> 1400 THEN
    RAISE EXCEPTION 'active reservation did not reduce available funds: %', summary;
  END IF;
  BEGIN
    PERFORM reserve_wallet_funds(
      test_wallet_id, 1500, 'withdrawal-reservation-2', 'reservation-key-0002',
      '00000000-0000-4000-8000-000000008002', actor_id, NOW() + INTERVAL '10 minutes'
    );
    RAISE EXCEPTION 'reservation exceeded available funds';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'reservation exceeded available funds' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM reserve_wallet_funds(
      test_wallet_id, 1001, 'withdrawal-reservation-1', 'reservation-key-0001',
      '00000000-0000-4000-8000-000000008001', actor_id, reservation.expires_at
    );
    RAISE EXCEPTION 'changed reservation reused an idempotency key';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'changed reservation reused an idempotency key' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM reserve_wallet_funds(
      test_wallet_id, 100, 'unauthorized-reservation', 'reservation-key-0003',
      '00000000-0000-4000-8000-000000008003', other_member_id, NOW() + INTERVAL '10 minutes'
    );
    RAISE EXCEPTION 'ordinary member reserved another user wallet';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'ordinary member reserved another user wallet' THEN RAISE; END IF;
  END;

  reservation := release_wallet_reservation(reservation.id, actor_id);
  replay := release_wallet_reservation(reservation.id, actor_id);
  IF reservation.state <> 'released' OR replay.id <> reservation.id
    OR (wallet_balance_summary(test_wallet_id)->>'availableBalanceMinor')::BIGINT <> 2400 THEN
    RAISE EXCEPTION 'active reservation release is not idempotent';
  END IF;

  reservation := reserve_wallet_funds(
    test_wallet_id, 1200, 'withdrawal-reservation-4', 'reservation-key-0004',
    '00000000-0000-4000-8000-000000008004', actor_id, NOW() + INTERVAL '10 minutes'
  );
  reservation := consume_wallet_reservation(reservation.id, actor_id);
  replay := consume_wallet_reservation(reservation.id, actor_id);
  IF reservation.state <> 'consumed' OR replay.consumed_journal_entry_id <> reservation.consumed_journal_entry_id
    OR (wallet_balance_summary(test_wallet_id)->>'ledgerBalanceMinor')::BIGINT <> 1200 THEN
    RAISE EXCEPTION 'reservation consumption is not idempotent';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM wallet_transactions
    WHERE journal_entry_id = reservation.consumed_journal_entry_id
      AND wallet_transactions.wallet_id = test_wallet_id AND amount_minor = 1200 AND direction = 'DEBIT'
  ) THEN RAISE EXCEPTION 'consumed reservation has no linked legacy evidence'; END IF;

  reservation := restore_wallet_reservation(reservation.id, actor_id, 'reservation-restored-0004');
  replay := restore_wallet_reservation(reservation.id, actor_id, 'reservation-restored-0004');
  IF reservation.state <> 'released' OR replay.restoration_journal_entry_id <> reservation.restoration_journal_entry_id
    OR (wallet_balance_summary(test_wallet_id)->>'ledgerBalanceMinor')::BIGINT <> 2400 THEN
    RAISE EXCEPTION 'reservation restoration is not idempotent';
  END IF;

  reservation := reserve_wallet_funds(
    test_wallet_id, 200, 'withdrawal-reservation-expiry', 'reservation-key-expiry',
    '00000000-0000-4000-8000-000000008005', actor_id, NOW() + INTERVAL '10 minutes'
  );
  BEGIN
    UPDATE fund_reservations SET amount_minor = amount_minor + 1 WHERE id = reservation.id;
    RAISE EXCEPTION 'reservation allowed a direct mutation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'reservation allowed a direct mutation' THEN RAISE; END IF;
  END;
  PERFORM set_config('microfams.reservation_engine', 'on', TRUE);
  UPDATE fund_reservations SET expires_at = NOW() - INTERVAL '1 second' WHERE id = reservation.id;
  PERFORM set_config('microfams.reservation_engine', '', TRUE);
  expired_count := expire_wallet_reservations(tenant_id);
  summary := wallet_balance_summary(test_wallet_id);
  IF expired_count <> 1
    OR (SELECT state FROM fund_reservations WHERE id = reservation.id) <> 'expired'
    OR (summary->>'availableBalanceMinor')::BIGINT <> 2400 THEN
    RAISE EXCEPTION 'reservation expiry mismatch: count %, state %, summary %',
      expired_count, (SELECT state FROM fund_reservations WHERE id = reservation.id), summary;
  END IF;

  transfer := atomic_p2p_transfer_minor(test_wallet_id, peer_wallet_id, 100, 'minor-p2p-0001');
  IF transfer->>'journal_entry_id' IS NULL
    OR (wallet_balance_summary(test_wallet_id)->>'ledgerBalanceMinor')::BIGINT <> 2300
    OR (wallet_balance_summary(peer_wallet_id)->>'ledgerBalanceMinor')::BIGINT <> 1650 THEN
    RAISE EXCEPTION 'minor-unit P2P adapter posted an incorrect amount';
  END IF;
  SELECT id INTO test_group_id FROM groups WHERE organization_id = tenant_id ORDER BY id LIMIT 1;
  summary := group_wallet_balance_summary(test_group_id);
  IF (summary->>'ledgerBalanceMinor')::BIGINT <> 150225
    OR summary ? 'balance' THEN
    RAISE EXCEPTION 'group wallet summary did not use the minor-unit contract';
  END IF;

  INSERT INTO group_consensus_requests (
    group_id, requested_by, target_user_id, amount, status, request_type, idempotency_key
  ) VALUES (
    test_group_id, actor_id, other_member_id, 1.00, 'PENDING', 'WITHDRAWAL',
    'group-withdrawal-key-0001'
  ) RETURNING id INTO group_request_id;
  INSERT INTO group_consensus_requests (
    group_id, requested_by, target_user_id, amount, status, request_type, idempotency_key
  ) VALUES (
    test_group_id, actor_id, other_member_id, 1.00, 'PENDING', 'WITHDRAWAL',
    'group-withdrawal-key-0001'
  ) ON CONFLICT (group_id, requested_by, idempotency_key)
    DO UPDATE SET updated_at = EXCLUDED.updated_at
    RETURNING id INTO group_request_replay_id;
  IF group_request_replay_id <> group_request_id THEN
    RAISE EXCEPTION 'group withdrawal replay created a duplicate consensus request';
  END IF;
END $$;

GRANT SELECT ON fund_reservations TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM fund_reservations) <> 3 THEN
    RAISE EXCEPTION 'tenant cannot read its fund reservations';
  END IF;
  BEGIN
    PERFORM reserve_wallet_funds(
      (SELECT id FROM user_wallets WHERE user_id = auth.uid() LIMIT 1),
      100, 'authenticated-call', 'authenticated-key', gen_random_uuid(), auth.uid(), NOW() + INTERVAL '5 minutes'
    );
    RAISE EXCEPTION 'authenticated role executed reservation command';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM fund_reservations) <> 0 THEN
    RAISE EXCEPTION 'fund reservations leaked across tenants';
  END IF;
END $$;
RESET ROLE;
