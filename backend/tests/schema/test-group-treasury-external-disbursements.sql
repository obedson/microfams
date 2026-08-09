-- GT-06B schema contract: an external disbursement pays a verified, separately
-- approved off-platform beneficiary through the shared provider payout stack.
-- Money is committed at begin but not posted; only a confirmed provider success
-- posts the deferred journal and consumes the reservation exactly once; a failure
-- releases the reservation and posts nothing; a provider success that arrives
-- after the payout already failed is recorded as an exception, never repaid.

SET search_path = public, extensions;
BEGIN;

DO $$
BEGIN
  -- The two new evidence tables must exist.
  IF to_regclass('public.group_treasury_beneficiaries') IS NULL
    OR to_regclass('public.group_treasury_late_payout_exceptions') IS NULL
  THEN RAISE EXCEPTION 'GT06B: expected external-disbursement tables are missing'; END IF;

  -- Every function the external channel depends on must exist.
  IF to_regproc('public.register_group_treasury_beneficiary') IS NULL
    OR to_regproc('public.approve_group_treasury_beneficiary') IS NULL
    OR to_regproc('public.reject_group_treasury_beneficiary') IS NULL
    OR to_regproc('public.request_group_treasury_external_disbursement') IS NULL
    OR to_regproc('public.begin_group_treasury_external_disbursement') IS NULL
    OR to_regproc('public.succeed_group_treasury_payout') IS NULL
    OR to_regproc('public.fail_group_treasury_payout') IS NULL
    OR to_regproc('public.record_group_treasury_late_payout_success') IS NULL
    OR to_regproc('public.group_treasury_external_clearing_account_id') IS NULL
  THEN RAISE EXCEPTION 'GT06B: expected external-disbursement functions are missing'; END IF;

  -- The shared payout row must admit the group_treasury source.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'payouts'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%source_type%'
      AND pg_get_constraintdef(oid) LIKE '%group_treasury%'
  ) THEN
    RAISE EXCEPTION 'GT06B: payouts source_type does not admit group_treasury';
  END IF;

  -- A verified beneficiary is evidence: it may be written only through the
  -- engine, so a direct insert has to fail.
  BEGIN
    INSERT INTO group_treasury_beneficiaries(
      organization_id, group_id, destination_ciphertext, destination_fingerprint,
      destination_masked, account_name_masked, provider_name, provider_environment,
      verification_reference, state, proposed_by, idempotency_key, request_hash,
      correlation_id
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), repeat('a', 64), repeat('a', 64),
      '******7890', 'Masked Name', 'testprovider', 'deterministic',
      'VRF-DIRECT-INSERT', 'pending_approval', gen_random_uuid(),
      'direct-insert-1', repeat('a', 64), gen_random_uuid()
    );
    RAISE EXCEPTION 'GT06B: a direct beneficiary insert was accepted';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06B:%' THEN RAISE; END IF;
  END;

  -- A late-success exception is evidence too, under the same lock.
  BEGIN
    INSERT INTO group_treasury_late_payout_exceptions(
      organization_id, disbursement_id, payout_id, provider_reference,
      amount_minor, currency, beneficiary_fingerprint
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'PROV-DIRECT',
      1000, 'NGN', repeat('a', 64)
    );
    RAISE EXCEPTION 'GT06B: a direct late-exception insert was accepted';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06B:%' THEN RAISE; END IF;
  END;
END $$;
-- End-to-end success: register a beneficiary, approve it, request and approve an
-- external disbursement, begin the payout, and confirm that success posts the
-- deferred journal, consumes the reservation once, and settles the budget.
DO $$
DECLARE
  v_owner UUID; v_second UUID; v_third UUID; v_org UUID; v_group UUID;
  v_owner_member UUID; v_second_member UUID; v_third_member UUID;
  v_budget UUID; v_disbursement UUID; v_reservation UUID; v_proposal UUID;
  v_treasury_account UUID; v_fingerprint TEXT; v_reqhash TEXT;
  v_beneficiary JSONB; v_beneficiary_id UUID;
  v_begin JSONB; v_payout_id UUID; v_internal_ref TEXT; v_payout_hash TEXT;
  v_payout payouts; v_journal UUID;
  v_available BIGINT; v_debits BIGINT; v_credits BIGINT; v_state TEXT;
BEGIN
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bx-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Chair', 'farmer') RETURNING id INTO v_owner;
  INSERT INTO organizations(name, slug, type, status, created_by)
    VALUES ('GT06B Org', 'gt06bx-org-' || substr(md5(random()::TEXT), 1, 8),
            'cooperative', 'active', v_owner) RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
    VALUES (v_org, v_owner, 'active', 'owner');
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status)
    VALUES (v_org, 'GT06B 2026', DATE '2026-01-01', DATE '2026-12-31', 'open');

  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bx-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Treasurer', 'farmer') RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bx-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Member', 'farmer') RETURNING id INTO v_third;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_third, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT06B Group', 'cooperative', v_owner, v_org, 10)
    RETURNING id INTO v_group;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_owner, 'owner', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_owner_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_second, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_second_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_third, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_third_member;

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT06B Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000901', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000902', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000903', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_second_member,
    NULL, '00000000-0000-4000-8000-000000000904', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000905', '2026-08-03T09:04:00Z');

  v_treasury_account := ensure_wallet_system_account(
    v_org, 'GROUP.' || upper(substr(md5(v_group::TEXT), 1, 16)) || '.TREASURY',
    'Group treasury funds held', 'liability', 'credit');
  PERFORM post_wallet_journal(v_org, 'test.seed', v_group::TEXT || ':fund',
    'Seed group treasury for GT06B',
    jsonb_build_array(
      jsonb_build_object('account_id', ensure_wallet_system_account(
        v_org, 'TEST.GT06BX.SOURCE', 'Test funding source', 'asset', 'debit'),
        'line_number', 1, 'side', 'debit', 'amount_minor', 500000, 'memo', 'seed'),
      jsonb_build_object('account_id', v_treasury_account,
        'line_number', 2, 'side', 'credit', 'amount_minor', 500000, 'memo', 'seed')
    ));

  INSERT INTO group_treasury_budgets(
    organization_id, group_id, constitution_id, budget_key, display_name,
    purpose, ceiling_minor, currency, period_start, period_end, state,
    opened_by, opened_at
  ) SELECT v_org, v_group, current_constitution_id, 'ops-2026q3', 'Q3 operations',
    'Operating expenditure for the third quarter', 400000, 'NGN',
    DATE '2026-07-01', DATE '2026-09-30', 'active', v_owner, NOW()
  FROM groups WHERE id = v_group RETURNING id INTO v_budget;

  -- The service layer owns the crypto; the fingerprint is a deterministic sha256
  -- of the destination, exactly the shape the registry constrains.
  v_fingerprint := encode(digest(convert_to('058|0123456789', 'UTF8'), 'sha256'), 'hex');
  v_reqhash := encode(digest(convert_to('gt06b-benef-req', 'UTF8'), 'sha256'), 'hex');

  -- The treasurer proposes the destination; a different officer verifies it. A
  -- destination is unusable until that second approval lands.
  v_beneficiary := register_group_treasury_beneficiary(
    v_org, v_group, v_second, NULL,
    'v1.' || v_fingerprint || '.tag.enc', v_fingerprint, '******6789',
    'Verified Supplier Ltd', 'testprovider', 'deterministic',
    'VRF-DETERMINISTIC-0001', 'gt06b-benef-1', v_reqhash,
    '00000000-0000-4000-8000-000000000906');
  v_beneficiary_id := (v_beneficiary->>'id')::UUID;
  IF v_beneficiary->>'state' <> 'pending_approval' THEN
    RAISE EXCEPTION 'GT06B: a freshly registered beneficiary was not pending';
  END IF;

  -- A destination cannot pay until it is verified.
  BEGIN
    v_disbursement := request_group_treasury_external_disbursement(
      v_org, v_group, v_budget, gen_random_uuid(), v_beneficiary_id,
      250000, 'NGN', 'Pay before the destination is verified',
      'https://evidence.example.test/gt06b-early', NOW() - INTERVAL '1 minute',
      NOW() + INTERVAL '7 days', v_second, 'gt06b-early', gen_random_uuid());
    RAISE EXCEPTION 'GT06B: an unverified beneficiary was paid';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06B:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED' THEN RAISE; END IF;
  END;

  -- The proposer cannot also verify their own destination.
  BEGIN
    PERFORM approve_group_treasury_beneficiary(
      v_org, v_group, v_beneficiary_id, v_second,
      'Trying to verify my own proposed destination.',
      '00000000-0000-4000-8000-000000000907');
    RAISE EXCEPTION 'GT06B: the proposer verified their own beneficiary';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06B:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK' THEN RAISE; END IF;
  END;

  v_beneficiary := approve_group_treasury_beneficiary(
    v_org, v_group, v_beneficiary_id, v_owner,
    'Confirmed the supplier account with the bank by phone.',
    '00000000-0000-4000-8000-000000000908');
  IF v_beneficiary->>'state' <> 'verified' THEN
    RAISE EXCEPTION 'GT06B: approval did not verify the beneficiary';
  END IF;

  -- Governance authorises the spend.
  v_proposal := create_group_proposal(v_org, v_group, v_second, 'treasury_disbursement',
    'Settle a verified supplier invoice through the external payout provider.',
    '[]', jsonb_build_object('budget_key', 'ops-2026q3', 'amount_minor', 250000),
    ARRAY[]::UUID[], '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000909', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-00000000090a', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000090b', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000090c', '2026-08-03T10:06:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_third, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000090d', '2026-08-03T10:07:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-00000000090e', '2026-08-03T11:00:00Z');

  v_disbursement := request_group_treasury_external_disbursement(
    v_org, v_group, v_budget, v_proposal, v_beneficiary_id,
    250000, 'NGN', 'Settle verified supplier invoice',
    'https://evidence.example.test/gt06b-inv-9', NOW() - INTERVAL '1 minute',
    NOW() + INTERVAL '7 days', v_second, 'gt06b-ext-1',
    '00000000-0000-4000-8000-00000000090f');
  IF v_disbursement IS NULL THEN
    RAISE EXCEPTION 'GT06B: external disbursement was not requested';
  END IF;

  -- A replayed request must return the same disbursement, never a second one.
  IF request_group_treasury_external_disbursement(
    v_org, v_group, v_budget, v_proposal, v_beneficiary_id,
    250000, 'NGN', 'Settle verified supplier invoice',
    'https://evidence.example.test/gt06b-inv-9', NOW() - INTERVAL '1 minute',
    NOW() + INTERVAL '7 days', v_second, 'gt06b-ext-1',
    '00000000-0000-4000-8000-000000000910'
  ) <> v_disbursement THEN
    RAISE EXCEPTION 'GT06B: a replayed external request created a second disbursement';
  END IF;

  v_reservation := approve_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000911');
  IF v_reservation IS NULL THEN
    RAISE EXCEPTION 'GT06B: external approval did not reserve funds';
  END IF;
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 250000 THEN
    RAISE EXCEPTION 'GT06B: available after reserving 250000 was % not 250000', v_available;
  END IF;

  -- Internal execution must refuse an external disbursement outright.
  BEGIN
    PERFORM execute_group_treasury_disbursement(
      v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000912');
    RAISE EXCEPTION 'GT06B: internal execution ran on an external disbursement';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06B:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_CHANNEL_NOT_INTERNAL' THEN RAISE; END IF;
  END;

  -- Begin: create and reserve the provider payout. No journal posts, and the
  -- reservation stays active — the money is committed but has not left the ledger.
  v_begin := begin_group_treasury_external_disbursement(
    v_org, v_disbursement, v_owner, 'testprovider', 'deterministic',
    '00000000-0000-4000-8000-000000000913');
  v_payout_id := (v_begin->>'payout_id')::UUID;
  v_internal_ref := v_begin->>'internal_reference';
  v_payout_hash := v_begin->>'request_hash';
  IF v_begin->>'state' <> 'reserved' THEN
    RAISE EXCEPTION 'GT06B: a begun payout was not reserved (got %)', v_begin->>'state';
  END IF;

  SELECT state INTO v_state FROM group_treasury_disbursements WHERE id = v_disbursement;
  IF v_state <> 'disbursing' THEN
    RAISE EXCEPTION 'GT06B: disbursement after begin was % not disbursing', v_state;
  END IF;
  SELECT source_type INTO v_state FROM payouts WHERE id = v_payout_id;
  IF v_state <> 'group_treasury' THEN
    RAISE EXCEPTION 'GT06B: payout source_type was % not group_treasury', v_state;
  END IF;
  IF EXISTS (
    SELECT 1 FROM group_treasury_disbursements
    WHERE id = v_disbursement AND execution_journal_entry_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'GT06B: begin posted a journal before provider confirmation';
  END IF;
  SELECT state INTO v_state FROM group_treasury_reservations WHERE id = v_reservation;
  IF v_state <> 'active' THEN
    RAISE EXCEPTION 'GT06B: begin did not leave the reservation active (got %)', v_state;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets
    WHERE id = v_budget AND committed_minor = 250000 AND disbursed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06B: begin changed the budget commitment';
  END IF;

  -- A repeated begin returns the in-flight payout rather than a second one.
  IF (begin_group_treasury_external_disbursement(
    v_org, v_disbursement, v_owner, 'testprovider', 'deterministic',
    '00000000-0000-4000-8000-000000000914')->>'payout_id')::UUID <> v_payout_id THEN
    RAISE EXCEPTION 'GT06B: a replayed begin created a second payout';
  END IF;

  -- The provider accepts the payout, then confirms success.
  PERFORM mark_payout_submitted(v_payout_id, v_payout_hash, 'PROV-REF-OK-1', FALSE);
  v_payout := succeed_group_treasury_payout(
    v_payout_id, v_internal_ref, 'PROV-REF-OK-1', 250000, 'NGN', v_fingerprint,
    v_org, 'testprovider', 'deterministic');
  v_journal := v_payout.success_journal_entry_id;
  IF v_journal IS NULL THEN
    RAISE EXCEPTION 'GT06B: confirmed success did not post a journal';
  END IF;

  -- The deferred journal debits the treasury and credits the clearing asset.
  SELECT COALESCE(SUM(CASE WHEN side = 'debit' THEN amount_minor ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN side = 'credit' THEN amount_minor ELSE 0 END), 0)
  INTO v_debits, v_credits FROM journal_lines WHERE journal_entry_id = v_journal;
  IF v_debits <> v_credits OR v_debits <> 250000 THEN
    RAISE EXCEPTION 'GT06B: success journal did not balance (% vs %)', v_debits, v_credits;
  END IF;

  SELECT state INTO v_state FROM group_treasury_disbursements WHERE id = v_disbursement;
  IF v_state <> 'executed' THEN
    RAISE EXCEPTION 'GT06B: disbursement after success was % not executed', v_state;
  END IF;
  SELECT state INTO v_state FROM group_treasury_reservations WHERE id = v_reservation;
  IF v_state <> 'consumed' THEN
    RAISE EXCEPTION 'GT06B: reservation after success was % not consumed', v_state;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets
    WHERE id = v_budget AND disbursed_minor = 250000 AND committed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06B: budget did not settle to spend after success';
  END IF;
  -- Debiting the treasury and consuming the reservation net to the same
  -- available figure the reservation already reflected.
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 250000 THEN
    RAISE EXCEPTION 'GT06B: available after success was % not 250000', v_available;
  END IF;

  -- Idempotent: a repeated success returns the same payout and posts nothing new.
  IF (succeed_group_treasury_payout(
    v_payout_id, v_internal_ref, 'PROV-REF-OK-1', 250000, 'NGN', v_fingerprint,
    v_org, 'testprovider', 'deterministic')).success_journal_entry_id <> v_journal THEN
    RAISE EXCEPTION 'GT06B: a replayed success posted a second journal';
  END IF;

  RAISE NOTICE 'GT06B: external disbursement success E2E passed';
END $$;

-- End-to-end failure and reconciliation: a provider that declines releases the
-- reservation and posts nothing; a success that arrives after that failure is
-- recorded as an exception and never repaid.
DO $$
DECLARE
  v_owner UUID; v_second UUID; v_third UUID; v_org UUID; v_group UUID;
  v_owner_member UUID; v_second_member UUID; v_third_member UUID;
  v_budget UUID; v_disbursement UUID; v_reservation UUID; v_proposal UUID;
  v_treasury_account UUID; v_fingerprint TEXT; v_reqhash TEXT;
  v_beneficiary JSONB; v_beneficiary_id UUID;
  v_begin JSONB; v_payout_id UUID; v_internal_ref TEXT; v_payout_hash TEXT;
  v_payout payouts; v_exception JSONB;
  v_available BIGINT; v_state TEXT;
BEGIN
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bf-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Fail Chair', 'farmer') RETURNING id INTO v_owner;
  INSERT INTO organizations(name, slug, type, status, created_by)
    VALUES ('GT06B Fail Org', 'gt06bf-org-' || substr(md5(random()::TEXT), 1, 8),
            'cooperative', 'active', v_owner) RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
    VALUES (v_org, v_owner, 'active', 'owner');
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status)
    VALUES (v_org, 'GT06B Fail 2026', DATE '2026-01-01', DATE '2026-12-31', 'open');

  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bf-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Fail Treasurer', 'farmer') RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06bf-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06B Fail Member', 'farmer') RETURNING id INTO v_third;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_third, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT06B Fail Group', 'cooperative', v_owner, v_org, 10)
    RETURNING id INTO v_group;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_owner, 'owner', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_owner_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_second, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_second_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_third, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_third_member;

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT06B Fail Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000930', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000931', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000932', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_second_member,
    NULL, '00000000-0000-4000-8000-000000000933', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000934', '2026-08-03T09:04:00Z');

  v_treasury_account := ensure_wallet_system_account(
    v_org, 'GROUP.' || upper(substr(md5(v_group::TEXT), 1, 16)) || '.TREASURY',
    'Group treasury funds held', 'liability', 'credit');
  PERFORM post_wallet_journal(v_org, 'test.seed', v_group::TEXT || ':fund',
    'Seed group treasury for GT06B failure path',
    jsonb_build_array(
      jsonb_build_object('account_id', ensure_wallet_system_account(
        v_org, 'TEST.GT06BF.SOURCE', 'Test funding source', 'asset', 'debit'),
        'line_number', 1, 'side', 'debit', 'amount_minor', 500000, 'memo', 'seed'),
      jsonb_build_object('account_id', v_treasury_account,
        'line_number', 2, 'side', 'credit', 'amount_minor', 500000, 'memo', 'seed')
    ));

  INSERT INTO group_treasury_budgets(
    organization_id, group_id, constitution_id, budget_key, display_name,
    purpose, ceiling_minor, currency, period_start, period_end, state,
    opened_by, opened_at
  ) SELECT v_org, v_group, current_constitution_id, 'ops-fail', 'Failure path',
    'Operating expenditure for the failure path', 400000, 'NGN',
    DATE '2026-07-01', DATE '2026-09-30', 'active', v_owner, NOW()
  FROM groups WHERE id = v_group RETURNING id INTO v_budget;

  v_fingerprint := encode(digest(convert_to('058|0123456789', 'UTF8'), 'sha256'), 'hex');
  v_reqhash := encode(digest(convert_to('gt06b-fail-benef', 'UTF8'), 'sha256'), 'hex');
  v_beneficiary := register_group_treasury_beneficiary(
    v_org, v_group, v_second, NULL,
    'v1.' || v_fingerprint || '.tag.enc', v_fingerprint, '******6789',
    'Verified Supplier Ltd', 'testprovider', 'deterministic',
    'VRF-DETERMINISTIC-0002', 'gt06b-fail-benef-1', v_reqhash,
    '00000000-0000-4000-8000-000000000935');
  v_beneficiary_id := (v_beneficiary->>'id')::UUID;
  v_beneficiary := approve_group_treasury_beneficiary(
    v_org, v_group, v_beneficiary_id, v_owner,
    'Confirmed the supplier account with the bank by phone.',
    '00000000-0000-4000-8000-000000000936');

  v_proposal := create_group_proposal(v_org, v_group, v_second, 'treasury_disbursement',
    'Settle a supplier invoice whose provider payout will then be declined.',
    '[]', jsonb_build_object('budget_key', 'ops-fail', 'amount_minor', 150000),
    ARRAY[]::UUID[], '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000937', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000938', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000939', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000093a', '2026-08-03T10:06:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_third, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000093b', '2026-08-03T10:07:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-00000000093c', '2026-08-03T11:00:00Z');

  v_disbursement := request_group_treasury_external_disbursement(
    v_org, v_group, v_budget, v_proposal, v_beneficiary_id,
    150000, 'NGN', 'Settle supplier invoice to be declined',
    'https://evidence.example.test/gt06b-fail-1', NOW() - INTERVAL '1 minute',
    NOW() + INTERVAL '7 days', v_second, 'gt06b-fail-1',
    '00000000-0000-4000-8000-00000000093d');
  v_reservation := approve_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-00000000093e');
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 350000 THEN
    RAISE EXCEPTION 'GT06B: available after reserving 150000 was % not 350000', v_available;
  END IF;

  v_begin := begin_group_treasury_external_disbursement(
    v_org, v_disbursement, v_owner, 'testprovider', 'deterministic',
    '00000000-0000-4000-8000-00000000093f');
  v_payout_id := (v_begin->>'payout_id')::UUID;
  v_internal_ref := v_begin->>'internal_reference';
  v_payout_hash := v_begin->>'request_hash';
  PERFORM mark_payout_submitted(v_payout_id, v_payout_hash, 'PROV-REF-FAIL-1', FALSE);

  -- The provider declines. The reservation is released, no journal exists, and
  -- the funds return to available.
  v_payout := fail_group_treasury_payout(
    v_payout_id, 'PROVIDER_DECLINED', 'The bank rejected the destination account.');
  IF v_payout.state <> 'failed' THEN
    RAISE EXCEPTION 'GT06B: a declined payout was % not failed', v_payout.state;
  END IF;
  SELECT state INTO v_state FROM group_treasury_disbursements WHERE id = v_disbursement;
  IF v_state <> 'failed' THEN
    RAISE EXCEPTION 'GT06B: disbursement after failure was % not failed', v_state;
  END IF;
  SELECT state INTO v_state FROM group_treasury_reservations WHERE id = v_reservation;
  IF v_state <> 'released' THEN
    RAISE EXCEPTION 'GT06B: reservation after failure was % not released', v_state;
  END IF;
  IF EXISTS (
    SELECT 1 FROM group_treasury_disbursements
    WHERE id = v_disbursement AND execution_journal_entry_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'GT06B: a failed payout posted a journal';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets
    WHERE id = v_budget AND committed_minor = 0 AND disbursed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06B: a failed payout left the budget committed';
  END IF;
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 500000 THEN
    RAISE EXCEPTION 'GT06B: failure did not restore available funds (got %)', v_available;
  END IF;

  -- Idempotent: a repeated failure returns the payout unchanged, never a second
  -- release.
  IF (fail_group_treasury_payout(
    v_payout_id, 'PROVIDER_DECLINED', 'Retried failure callback.')).state <> 'failed' THEN
    RAISE EXCEPTION 'GT06B: a replayed failure changed the payout';
  END IF;
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 500000 THEN
    RAISE EXCEPTION 'GT06B: a replayed failure freed funds twice (got %)', v_available;
  END IF;

  -- Late success: the provider now reports the money did leave. It is recorded as
  -- an exception, never repaid — repaying would debit the treasury twice.
  v_exception := record_group_treasury_late_payout_success(
    v_payout_id, v_org, 'PROV-REF-LATE-1', 150000, 'NGN', v_fingerprint,
    'testprovider', 'deterministic',
    jsonb_build_object('source', 'provider_webhook', 'observed_at', '2026-08-05T00:00:00Z'));
  IF (v_exception->'evidence_snapshot'->>'recorded_without_repaying') <> 'true' THEN
    RAISE EXCEPTION 'GT06B: a late success was not marked recorded_without_repaying';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_late_payout_exceptions
    WHERE payout_id = v_payout_id AND provider_reference = 'PROV-REF-LATE-1'
  ) THEN
    RAISE EXCEPTION 'GT06B: the late success left no reconciliation exception';
  END IF;
  -- Nothing was repaid: budget and available are exactly where the failure left them.
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets
    WHERE id = v_budget AND committed_minor = 0 AND disbursed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06B: a late success moved the budget';
  END IF;
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 500000 THEN
    RAISE EXCEPTION 'GT06B: a late success re-debited the treasury (got %)', v_available;
  END IF;
  SELECT state INTO v_state FROM group_treasury_disbursements WHERE id = v_disbursement;
  IF v_state <> 'failed' THEN
    RAISE EXCEPTION 'GT06B: a late success revived the disbursement (got %)', v_state;
  END IF;

  -- Idempotent on (payout_id, provider_reference).
  IF (record_group_treasury_late_payout_success(
    v_payout_id, v_org, 'PROV-REF-LATE-1', 150000, 'NGN', v_fingerprint,
    'testprovider', 'deterministic',
    jsonb_build_object('source', 'provider_webhook'))->>'id') <> (v_exception->>'id') THEN
    RAISE EXCEPTION 'GT06B: a replayed late success recorded a second exception';
  END IF;

  RAISE NOTICE 'GT06B: external disbursement failure and reconciliation E2E passed';
END $$;

SELECT 'group treasury external disbursement tests passed' AS result;

ROLLBACK;


