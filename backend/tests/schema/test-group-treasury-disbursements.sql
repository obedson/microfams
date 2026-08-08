-- GT-06A schema contract: group spending is governed, funds are reserved against
-- posted journals rather than a mutable balance, maker and checker are distinct
-- people, execution revalidates what approval assumed, and a reservation is
-- consumed or released exactly once.

SET search_path = public, extensions;
BEGIN;

DO $$
BEGIN
  -- Every table and function the domain depends on must exist.
  IF to_regclass('public.group_treasury_budgets') IS NULL
    OR to_regclass('public.group_treasury_disbursements') IS NULL
    OR to_regclass('public.group_treasury_reservations') IS NULL
    OR to_regclass('public.group_treasury_events') IS NULL
  THEN RAISE EXCEPTION 'GT06A: expected treasury tables are missing'; END IF;

  IF to_regprocedure('public.approve_group_treasury_disbursement(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.execute_group_treasury_disbursement(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.release_group_treasury_reservation(uuid,uuid,text,uuid,uuid)') IS NULL
    OR to_regprocedure('public.reverse_group_treasury_disbursement(uuid,uuid,text,uuid,uuid)') IS NULL
    OR to_regprocedure('public.group_treasury_available_minor(uuid,uuid)') IS NULL
    OR to_regprocedure('public.group_treasury_checker_permitted(uuid,uuid,uuid)') IS NULL
  THEN RAISE EXCEPTION 'GT06A: expected treasury functions are missing'; END IF;

  -- Clause 2: reservations must never be written by hand. The engine flag is the
  -- only way in, so a direct insert has to fail.
  BEGIN
    INSERT INTO group_treasury_reservations(
      organization_id, group_id, budget_id, disbursement_id, source_account_id,
      amount_minor, currency, state
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), 1000, 'NGN', 'active'
    );
    RAISE EXCEPTION 'GT06A: a direct reservation insert was accepted';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
  END;

  -- Clause 1: a disbursement must carry a currency the ledger understands and a
  -- positive amount. Both are structural, not application-level.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'group_treasury_disbursements'::regclass
      AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%amount_minor%'
  ) THEN
    RAISE EXCEPTION 'GT06A: disbursement amount is not constrained';
  END IF;
END $$;

-- End-to-end: request, approve, execute, and confirm the money moved by journal.
DO $$
DECLARE
  v_owner UUID; v_second UUID; v_third UUID;
  v_org UUID; v_group UUID;
  v_owner_member UUID; v_second_member UUID; v_third_member UUID;
  v_budget UUID; v_disbursement UUID; v_reservation UUID;
  v_proposal UUID; v_journal UUID;
  v_treasury_account UUID; v_payable_account UUID;
  v_available BIGINT; v_debits BIGINT; v_credits BIGINT;
  v_state TEXT; v_released BOOLEAN;
BEGIN
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06a-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Chair', 'farmer')
    RETURNING id INTO v_owner;
  INSERT INTO organizations(name, slug, type, status, created_by)
    VALUES ('GT06A Org', 'gt06a-org-' || substr(md5(random()::TEXT), 1, 8),
            'cooperative', 'active', v_owner)
    RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
    VALUES (v_org, v_owner, 'active', 'owner');
  -- Clause 6 posts through the ledger, which refuses an entry that falls outside
  -- an open accounting period.
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status)
    VALUES (v_org, 'GT06A 2026', DATE '2026-01-01', DATE '2026-12-31', 'open');

  INSERT INTO users(email, password, name, role) VALUES
    ('gt06a-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Treasurer', 'farmer')
    RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());

  INSERT INTO users(email, password, name, role) VALUES
    ('gt06a-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Beneficiary', 'farmer')
    RETURNING id INTO v_third;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_third, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT06A Group', 'cooperative', v_owner, v_org, 10)
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

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT06A Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000801', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000802', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000803', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_second_member,
    NULL, '00000000-0000-4000-8000-000000000804', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000805', '2026-08-03T09:04:00Z');

  -- Clause 3 needs an office that can countersign. The chair must hold the
  -- approve permission for any disbursement to be executable at all.
  IF NOT EXISTS (
    SELECT 1 FROM group_office_definitions
    WHERE group_id = v_group AND office_key = 'chair'
      AND permissions @> ARRAY['groups.treasury.approve']::TEXT[]
  ) THEN
    RAISE EXCEPTION 'GT06A: chair office cannot act as treasury checker';
  END IF;

  -- Fund the treasury by posting a journal, which is the only way a balance
  -- comes to exist under clause 2.
  v_treasury_account := ensure_wallet_system_account(
    v_org, 'GROUP.' || upper(substr(md5(v_group::TEXT), 1, 16)) || '.TREASURY',
    'Group treasury funds held', 'liability', 'credit');
  PERFORM post_wallet_journal(v_org, 'test.seed', v_group::TEXT || ':fund',
    'Seed group treasury for GT06A',
    jsonb_build_array(
      jsonb_build_object('account_id', ensure_wallet_system_account(
        v_org, 'TEST.GT06A.SOURCE', 'Test funding source', 'asset', 'debit'),
        'line_number', 1, 'side', 'debit', 'amount_minor', 500000, 'memo', 'seed'),
      jsonb_build_object('account_id', v_treasury_account,
        'line_number', 2, 'side', 'credit', 'amount_minor', 500000, 'memo', 'seed')
    ));

  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 500000 THEN
    RAISE EXCEPTION 'GT06A: available funds derived from journals were % not 500000', v_available;
  END IF;

  INSERT INTO group_treasury_budgets(
    organization_id, group_id, constitution_id, budget_key, display_name,
    purpose, ceiling_minor, currency, period_start, period_end, state,
    opened_by, opened_at
  ) SELECT v_org, v_group, current_constitution_id, 'ops-2026q3', 'Q3 operations',
    'Operating expenditure for the third quarter', 400000, 'NGN',
    DATE '2026-07-01', DATE '2026-09-30', 'active', v_owner, NOW()
  FROM groups WHERE id = v_group
  RETURNING id INTO v_budget;

  -- The treasurer proposes; a treasury proposal carries the governance decision.
  v_proposal := create_group_proposal(v_org, v_group, v_second, 'treasury_disbursement',
    'Reimburse a member for approved operating expenses incurred on behalf of the group.',
    '[]', jsonb_build_object('budget_key', 'ops-2026q3', 'amount_minor', 120000),
    ARRAY[]::UUID[], '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000806', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000807', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000808', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000809', '2026-08-03T10:06:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_third, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000810', '2026-08-03T10:07:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000811', '2026-08-03T11:00:00Z');

  v_disbursement := request_group_treasury_disbursement(
    v_org, v_group, v_budget, v_proposal, 'member', v_third_member, NULL, NULL,
    120000, 'NGN', 'Reimburse approved operating expenses', 'https://evidence.example.test/gt06a-req-1',
    NOW() - INTERVAL '1 minute', NOW() + INTERVAL '7 days', v_second,
    'gt06a-req-1', '00000000-0000-4000-8000-000000000812');
  IF v_disbursement IS NULL THEN
    RAISE EXCEPTION 'GT06A: disbursement was not requested';
  END IF;

  -- Clause 1: the same idempotency key must return the same disbursement rather
  -- than creating a second one.
  IF request_group_treasury_disbursement(
    v_org, v_group, v_budget, v_proposal, 'member', v_third_member, NULL, NULL,
    120000, 'NGN', 'Reimburse approved operating expenses',
    'https://evidence.example.test/gt06a-req-1',
    NOW() - INTERVAL '1 minute', NOW() + INTERVAL '7 days', v_second,
    'gt06a-req-1', '00000000-0000-4000-8000-000000000813'
  ) <> v_disbursement THEN
    RAISE EXCEPTION 'GT06A: a replayed request created a second disbursement';
  END IF;

  -- Clause 3: the proposer cannot be their own final checker.
  BEGIN
    PERFORM approve_group_treasury_disbursement(
      v_org, v_disbursement, v_second, '00000000-0000-4000-8000-000000000814');
    RAISE EXCEPTION 'GT06A: the proposer was allowed to self-approve';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_SELF_APPROVAL_FORBIDDEN' THEN RAISE; END IF;
  END;

  -- Clause 3: the beneficiary cannot approve their own payment.
  BEGIN
    PERFORM approve_group_treasury_disbursement(
      v_org, v_disbursement, v_third, '00000000-0000-4000-8000-000000000815');
    RAISE EXCEPTION 'GT06A: the beneficiary was allowed to approve';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
    IF SQLERRM NOT IN (
      'GROUP_TREASURY_CHECKER_IS_BENEFICIARY', 'GROUP_TREASURY_CHECKER_NOT_PERMITTED'
    ) THEN RAISE; END IF;
  END;

  -- Execution before approval must be refused outright.
  BEGIN
    PERFORM execute_group_treasury_disbursement(
      v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000816');
    RAISE EXCEPTION 'GT06A: an unapproved disbursement was executed';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_DISBURSEMENT_NOT_APPROVED' THEN RAISE; END IF;
  END;

  -- The chair countersigns, which reserves the funds atomically.
  v_reservation := approve_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000817');
  IF v_reservation IS NULL THEN
    RAISE EXCEPTION 'GT06A: approval did not create a reservation';
  END IF;

  -- Clause 2: reserved funds are no longer available to a second commitment.
  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 380000 THEN
    RAISE EXCEPTION 'GT06A: available funds after reserving 120000 were % not 380000', v_available;
  END IF;

  -- Clause 5: the snapshot must record what was true at approval.
  SELECT available_minor_at_approval INTO v_available
  FROM group_treasury_disbursements WHERE id = v_disbursement;
  IF v_available <> 500000 THEN
    RAISE EXCEPTION 'GT06A: approval snapshot recorded % not 500000', v_available;
  END IF;

  v_journal := execute_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000818');
  IF v_journal IS NULL THEN
    RAISE EXCEPTION 'GT06A: execution did not post a journal';
  END IF;

  -- Clause 6: the posted entry must balance.
  SELECT COALESCE(SUM(CASE WHEN side = 'debit' THEN amount_minor ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN side = 'credit' THEN amount_minor ELSE 0 END), 0)
  INTO v_debits, v_credits FROM journal_lines WHERE journal_entry_id = v_journal;
  IF v_debits <> v_credits OR v_debits <> 120000 THEN
    RAISE EXCEPTION 'GT06A: execution journal did not balance (% vs %)', v_debits, v_credits;
  END IF;

  -- Clause 7: re-executing must return the same journal, not post a second one.
  IF execute_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000819'
  ) <> v_journal THEN
    RAISE EXCEPTION 'GT06A: a replayed execution posted a second journal';
  END IF;

  -- Clause 7: the reservation is consumed exactly once and cannot be released
  -- after the money has already moved.
  SELECT state INTO v_state FROM group_treasury_reservations WHERE id = v_reservation;
  IF v_state <> 'consumed' THEN
    RAISE EXCEPTION 'GT06A: reservation state after execution was % not consumed', v_state;
  END IF;
  BEGIN
    PERFORM release_group_treasury_reservation(
      v_org, v_disbursement, 'TEST', v_owner, '00000000-0000-4000-8000-000000000820');
    RAISE EXCEPTION 'GT06A: an executed disbursement was released';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_ALREADY_EXECUTED' THEN RAISE; END IF;
  END;

  -- The budget must show the spend as actual, with nothing left committed.
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets
    WHERE id = v_budget AND disbursed_minor = 120000 AND committed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06A: budget totals did not settle after execution';
  END IF;

  RAISE NOTICE 'GT06A: governed disbursement E2E passed';
END $$;

-- A disbursement that exceeds available funds must be refused at approval, and
-- an abandoned one must give its reservation back exactly once.
DO $$
DECLARE
  v_owner UUID; v_second UUID; v_third UUID; v_org UUID; v_group UUID;
  v_owner_member UUID; v_second_member UUID; v_third_member UUID;
  v_budget UUID; v_disbursement UUID; v_proposal UUID;
  v_treasury_account UUID; v_available BIGINT; v_released BOOLEAN; v_state TEXT;
BEGIN
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06b-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Neg Chair', 'farmer')
    RETURNING id INTO v_owner;
  INSERT INTO organizations(name, slug, type, status, created_by)
    VALUES ('GT06A Neg Org', 'gt06b-org-' || substr(md5(random()::TEXT), 1, 8),
            'cooperative', 'active', v_owner)
    RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
    VALUES (v_org, v_owner, 'active', 'owner');
  -- Clause 6 posts through the ledger, which refuses an entry that falls outside
  -- an open accounting period.
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status)
    VALUES (v_org, 'GT06A 2026', DATE '2026-01-01', DATE '2026-12-31', 'open');
  INSERT INTO users(email, password, name, role) VALUES
    ('gt06b-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Neg Treasurer', 'farmer')
    RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());

  INSERT INTO users(email, password, name, role) VALUES
    ('gt06b-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT06A Neg Beneficiary', 'farmer')
    RETURNING id INTO v_third;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_third, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT06A Neg Group', 'cooperative', v_owner, v_org, 10)
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

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT06A Neg Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000830', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000831', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000832', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_second_member,
    NULL, '00000000-0000-4000-8000-000000000833', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000834', '2026-08-03T09:04:00Z');

  -- Fund only a small amount, then try to spend more than exists.
  v_treasury_account := ensure_wallet_system_account(
    v_org, 'GROUP.' || upper(substr(md5(v_group::TEXT), 1, 16)) || '.TREASURY',
    'Group treasury funds held', 'liability', 'credit');
  PERFORM post_wallet_journal(v_org, 'test.seed', v_group::TEXT || ':fund',
    'Seed small group treasury for GT06A negative path',
    jsonb_build_array(
      jsonb_build_object('account_id', ensure_wallet_system_account(
        v_org, 'TEST.GT06B.SOURCE', 'Test funding source', 'asset', 'debit'),
        'line_number', 1, 'side', 'debit', 'amount_minor', 50000, 'memo', 'seed'),
      jsonb_build_object('account_id', v_treasury_account,
        'line_number', 2, 'side', 'credit', 'amount_minor', 50000, 'memo', 'seed')
    ));

  INSERT INTO group_treasury_budgets(
    organization_id, group_id, constitution_id, budget_key, display_name,
    purpose, ceiling_minor, currency, period_start, period_end, state,
    opened_by, opened_at
  ) SELECT v_org, v_group, current_constitution_id, 'ops-neg', 'Negative path',
    'Operating expenditure for the negative path', 400000, 'NGN',
    DATE '2026-07-01', DATE '2026-09-30', 'active', v_owner, NOW()
  FROM groups WHERE id = v_group
  RETURNING id INTO v_budget;

  v_proposal := create_group_proposal(v_org, v_group, v_second, 'treasury_disbursement',
    'Attempt a disbursement larger than the funds the group actually holds.',
    '[]', jsonb_build_object('budget_key', 'ops-neg', 'amount_minor', 200000),
    ARRAY[]::UUID[], '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000835', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000836', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000837', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000838', '2026-08-03T10:06:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_third, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000083a', '2026-08-03T10:07:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000839', '2026-08-03T11:00:00Z');

  v_disbursement := request_group_treasury_disbursement(
    v_org, v_group, v_budget, v_proposal, 'member', v_third_member, NULL, NULL,
    200000, 'NGN', 'Spend more than the treasury holds', 'https://evidence.example.test/gt06b-req-1',
    NOW() - INTERVAL '1 minute', NOW() + INTERVAL '7 days', v_second,
    'gt06b-req-1', '00000000-0000-4000-8000-000000000840');

  -- Clause 2: approval must fail when the group cannot cover the amount.
  BEGIN
    PERFORM approve_group_treasury_disbursement(
      v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000841');
    RAISE EXCEPTION 'GT06A: a disbursement exceeding available funds was approved';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE 'GT06A:%' THEN RAISE; END IF;
    IF SQLERRM <> 'GROUP_TREASURY_INSUFFICIENT_AVAILABLE_FUNDS' THEN RAISE; END IF;
  END;

  -- No reservation may exist after a refused approval, and the budget must show
  -- nothing committed.
  IF EXISTS (
    SELECT 1 FROM group_treasury_reservations WHERE disbursement_id = v_disbursement
  ) THEN
    RAISE EXCEPTION 'GT06A: a refused approval left a reservation behind';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets WHERE id = v_budget AND committed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06A: a refused approval committed budget funds';
  END IF;

  -- Now approve an affordable amount and abandon it: the release must return the
  -- funds, and a second release must be a no-op rather than a double refund.
  v_proposal := create_group_proposal(v_org, v_group, v_second, 'treasury_disbursement',
    'Approve a small disbursement that will then be abandoned before execution.',
    '[]', jsonb_build_object('budget_key', 'ops-neg', 'amount_minor', 20000),
    ARRAY[]::UUID[], '2026-08-04T10:00:00Z', '2026-08-04T11:00:00Z',
    '00000000-0000-4000-8000-000000000842', '2026-08-04T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000843', '2026-08-04T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000844', '2026-08-04T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000845', '2026-08-04T10:06:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_third, v_proposal, 'approve',
    '00000000-0000-4000-8000-00000000084a', '2026-08-04T10:07:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000846', '2026-08-04T11:00:00Z');

  v_disbursement := request_group_treasury_disbursement(
    v_org, v_group, v_budget, v_proposal, 'member', v_third_member, NULL, NULL,
    20000, 'NGN', 'Small disbursement to be abandoned', 'https://evidence.example.test/gt06b-req-2',
    NOW() - INTERVAL '1 minute', NOW() + INTERVAL '7 days', v_second,
    'gt06b-req-2', '00000000-0000-4000-8000-000000000847');
  PERFORM approve_group_treasury_disbursement(
    v_org, v_disbursement, v_owner, '00000000-0000-4000-8000-000000000848');

  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 30000 THEN
    RAISE EXCEPTION 'GT06A: available after reserving 20000 of 50000 was %', v_available;
  END IF;

  v_released := release_group_treasury_reservation(
    v_org, v_disbursement, 'ABANDONED', v_owner,
    '00000000-0000-4000-8000-000000000849');
  IF NOT v_released THEN
    RAISE EXCEPTION 'GT06A: the first release did not report success';
  END IF;

  v_available := group_treasury_available_minor(v_org, v_group);
  IF v_available <> 50000 THEN
    RAISE EXCEPTION 'GT06A: release did not restore available funds (got %)', v_available;
  END IF;

  -- Clause 7: exactly once. A second release changes nothing.
  IF release_group_treasury_reservation(
    v_org, v_disbursement, 'ABANDONED', v_owner,
    '00000000-0000-4000-8000-000000000850'
  ) THEN
    RAISE EXCEPTION 'GT06A: a second release freed the same funds twice';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_treasury_budgets WHERE id = v_budget AND committed_minor = 0
  ) THEN
    RAISE EXCEPTION 'GT06A: committed funds survived the release';
  END IF;

  RAISE NOTICE 'GT06A: treasury negative-path tests passed';
END $$;

SELECT 'group treasury disbursement tests passed' AS result;

ROLLBACK;
