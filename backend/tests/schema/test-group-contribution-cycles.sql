-- GT-05 schema contract: a cycle binds one immutable rule version, obligations
-- preserve their original amounts, excess is never silently absorbed, and a
-- closed cycle is immutable.

SET search_path = public, extensions;
BEGIN;

DO $$
DECLARE v_failed BOOLEAN;
BEGIN
  -- Every table and function the domain depends on must exist.
  IF to_regclass('public.group_contribution_cycles') IS NULL
    OR to_regclass('public.group_contribution_obligations') IS NULL
    OR to_regclass('public.group_contribution_obligation_adjustments') IS NULL
    OR to_regclass('public.group_contribution_settlements') IS NULL
    OR to_regclass('public.group_contribution_excess_payments') IS NULL
  THEN RAISE EXCEPTION 'GT05: expected cycle tables are missing'; END IF;

  IF to_regprocedure('public.open_group_contribution_cycle(uuid,uuid,uuid,uuid,text,date,date,date,text,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.settle_group_contribution_obligation(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.adjust_group_contribution_obligation(uuid,uuid,uuid,uuid,text,bigint,text,text,jsonb,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.transition_group_contribution_cycle(uuid,uuid,uuid,uuid,text,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.close_group_contribution_cycle(uuid,uuid,uuid,uuid,text,boolean,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.cancel_group_contribution_cycle(uuid,uuid,uuid,uuid,text,text,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.read_group_contribution_cycle_dashboard(uuid,uuid,uuid,uuid)') IS NULL
  THEN RAISE EXCEPTION 'GT05: expected cycle functions are missing'; END IF;

  -- Direct writes must be refused: the engine lock is the only way in.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_cycles(
      organization_id, group_id, product_id, rule_version_id, constitution_id,
      period_key, period_start, period_end, timezone, due_date, grace_end_date, currency
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), '2026-09', DATE '2026-09-01', DATE '2026-09-30',
      'Africa/Lagos', DATE '2026-09-25', DATE '2026-09-30', 'NGN'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_ENGINE_REQUIRED%' THEN v_failed := TRUE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: direct cycle insert was not refused'; END IF;

  RAISE NOTICE 'GT05 structural and engine-lock assertions passed';
END $$;

-- Date ordering and state/timestamp coupling are table-level CHECKs, so assert
-- them directly without needing a full tenant graph.
DO $$
DECLARE v_failed BOOLEAN;
BEGIN
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  -- A due date before the period starts would bill members for a period that
  -- has not begun.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_cycles(
      organization_id, group_id, product_id, rule_version_id, constitution_id,
      period_key, period_start, period_end, timezone, due_date, grace_end_date, currency
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), '2026-09', DATE '2026-09-01', DATE '2026-09-30',
      'Africa/Lagos', DATE '2026-08-01', DATE '2026-09-30', 'NGN'
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: due-date CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a due date before the period start was accepted'; END IF;

  -- Grace may not end before the payment is even due.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_cycles(
      organization_id, group_id, product_id, rule_version_id, constitution_id,
      period_key, period_start, period_end, timezone, due_date, grace_end_date, currency
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), '2026-09', DATE '2026-09-01', DATE '2026-09-30',
      'Africa/Lagos', DATE '2026-09-25', DATE '2026-09-20', 'NGN'
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: grace-end CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a grace end before the due date was accepted'; END IF;

  -- A draft cycle has not been opened, so it may not carry an opened_at.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_cycles(
      organization_id, group_id, product_id, rule_version_id, constitution_id,
      period_key, period_start, period_end, timezone, due_date, grace_end_date,
      currency, state, opened_at
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), '2026-09', DATE '2026-09-01', DATE '2026-09-30',
      'Africa/Lagos', DATE '2026-09-25', DATE '2026-09-30', 'NGN', 'draft', NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: draft-state CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a draft cycle accepted an opened_at'; END IF;

  -- A closed cycle must name the accounting period it landed in and why it was
  -- closed; clause 6 makes both part of the record.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_cycles(
      organization_id, group_id, product_id, rule_version_id, constitution_id,
      period_key, period_start, period_end, timezone, due_date, grace_end_date,
      currency, state, opened_at, closing_started_at, closed_at
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), '2026-09', DATE '2026-09-01', DATE '2026-09-30',
      'Africa/Lagos', DATE '2026-09-25', DATE '2026-09-30', 'NGN', 'closed',
      NOW(), NOW(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: close-evidence CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a closed cycle was accepted without close evidence'; END IF;

  RAISE NOTICE 'GT05 cycle date and state invariants passed';
END $$;

-- An obligation may not be adjusted below zero, and an adjustment row must
-- carry a real delta and preserve the original expected amount.
DO $$
DECLARE v_failed BOOLEAN;
BEGIN
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_obligations(
      organization_id, group_id, cycle_id, product_id, rule_version_id,
      member_id, user_id, expected_minor, adjusted_minor
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 100000, -200000
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: obligation floor CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: an obligation was adjusted below zero'; END IF;

  -- A zero-delta adjustment records nothing and must be refused.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_obligation_adjustments(
      organization_id, cycle_id, obligation_id, adjustment_kind, reason_code,
      reason, delta_minor, original_expected_minor, applied_to_state, created_by
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'waiver',
      'HARDSHIP', 'Member hardship waiver', 0, 100000, 'waived', gen_random_uuid()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: adjustment delta CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a zero-delta adjustment was accepted'; END IF;

  -- An excess row must record a positive amount; zero is not an excess.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_excess_payments(
      organization_id, group_id, cycle_id, obligation_id, allocation_id,
      member_id, excess_minor
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), gen_random_uuid(), 0
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT05: excess amount CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a zero excess payment was accepted'; END IF;

  RAISE NOTICE 'GT05 obligation and excess invariants passed';
END $$;

-- The engine must actually run, not merely exist. This drives a product and
-- rule through governance, opens a cycle, and then asserts the invariants that
-- make a cycle trustworthy: obligations generated from the opening snapshot, an
-- immutable original amount, a rule that cannot be superseded mid-cycle, and a
-- closed cycle that refuses further writes.
DO $$
DECLARE
  v_org UUID; v_owner UUID; v_second UUID;
  v_group UUID; v_owner_member UUID; v_second_member UUID;
  v_proposal UUID; v_decided group_proposals;
  v_product UUID; v_cycle UUID; v_obligation UUID;
  v_failed BOOLEAN;
  v_count INTEGER;
  v_expected BIGINT;
  v_adjusted BIGINT;
  v_state TEXT;
  v_dashboard JSONB;
BEGIN
  INSERT INTO users(email, password, name, role) VALUES
    ('gt05-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT05 Chair', 'farmer')
    RETURNING id INTO v_owner;
  INSERT INTO organizations(name, slug, type, status, created_by)
    VALUES ('GT05 Org', 'gt05-org-' || substr(md5(random()::TEXT), 1, 8),
            'cooperative', 'active', v_owner)
    RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
    VALUES (v_org, v_owner, 'active', 'owner');
  -- Clause 6 ties a close to an accounting period, so the tenant needs one that
  -- covers the cycle and is still open.
  INSERT INTO accounting_periods(organization_id, name, starts_on, ends_on, status)
    VALUES (v_org, 'GT05 2026-09', DATE '2026-09-01', DATE '2026-09-30', 'open');

  INSERT INTO users(email, password, name, role) VALUES
    ('gt05-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT05 Second Voter', 'farmer')
    RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT05 Group', 'cooperative', v_owner, v_org, 10) RETURNING id INTO v_group;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_owner, 'owner', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_owner_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_second, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_second_member;

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT05 Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000751', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000752', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000753', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000754', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000755', '2026-08-03T09:04:00Z');

  v_proposal := create_group_proposal(v_org, v_group, v_owner, 'contribution_rule',
    'Adopt a monthly periodic due for group operating costs.', '[]',
    jsonb_build_object(
      'action', 'adopt', 'product_key', 'monthly_due', 'display_name', 'Monthly due',
      'product_class', 'periodic_due', 'purpose', 'Cover operating costs',
      'amount_minor', 250000, 'currency', 'NGN',
      'permitted_rails', jsonb_build_array('paystack'),
      'refund_rule_code', 'NO_REFUND', 'revenue_account_code', 'DUES_INCOME',
      'due_schedule', jsonb_build_object('grace_period_days', 5)
    ), ARRAY[]::UUID[],
    '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000756', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000757', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000758', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000759', '2026-08-03T10:06:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000760', '2026-08-03T11:00:00Z');
  PERFORM execute_group_contribution_rule_proposal(v_org, v_group, v_owner, v_proposal, 3,
    '00000000-0000-4000-8000-000000000761', '2026-08-03T11:01:00Z');

  SELECT id INTO v_product FROM group_contribution_products
  WHERE organization_id = v_org AND group_id = v_group AND product_key = 'monthly_due';
  IF v_product IS NULL THEN RAISE EXCEPTION 'GT05: contribution product was not created'; END IF;

  -- Open a cycle: obligations must be generated for both active members.
  v_cycle := open_group_contribution_cycle(
    v_org, v_group, v_owner, v_product, '2026-09',
    DATE '2026-09-01', DATE '2026-09-30', DATE '2026-09-25', 'Africa/Lagos',
    '00000000-0000-4000-8000-000000000762', '2026-09-01T00:00:00Z');
  IF v_cycle IS NULL THEN RAISE EXCEPTION 'GT05: cycle was not opened'; END IF;

  SELECT obligation_count, expected_total_minor, state
  INTO v_count, v_expected, v_state
  FROM group_contribution_cycles WHERE id = v_cycle;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GT05: expected 2 obligations from the snapshot, got %', v_count;
  END IF;
  IF v_expected <> 500000 THEN
    RAISE EXCEPTION 'GT05: expected total of 500000, got %', v_expected;
  END IF;
  IF v_state <> 'open' THEN RAISE EXCEPTION 'GT05: opened cycle is not open'; END IF;
  -- Clause 1: the eligibility snapshot must be captured, not left empty.
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_cycles
    WHERE id = v_cycle AND jsonb_array_length(eligibility_snapshot->'members') = 2
  ) THEN RAISE EXCEPTION 'GT05: eligibility snapshot was not captured'; END IF;
  -- The grace end must come from the rule's disclosed grace period.
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_cycles
    WHERE id = v_cycle AND grace_end_date = DATE '2026-09-30'
  ) THEN RAISE EXCEPTION 'GT05: grace end was not derived from the rule'; END IF;

  -- The snapshot is written once at open and locked thereafter, so a later
  -- membership change cannot be backdated into the billing record.
  v_failed := FALSE;
  BEGIN
    PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
    UPDATE group_contribution_cycles
    SET eligibility_snapshot = '{"members": []}'::JSONB WHERE id = v_cycle;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CYCLE_SNAPSHOT_IMMUTABLE%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: the eligibility snapshot was rewritten after open'; END IF;

  -- Opening the same correlation twice must return the same cycle.
  IF open_group_contribution_cycle(
    v_org, v_group, v_owner, v_product, '2026-09',
    DATE '2026-09-01', DATE '2026-09-30', DATE '2026-09-25', 'Africa/Lagos',
    '00000000-0000-4000-8000-000000000762', '2026-09-01T00:00:00Z') <> v_cycle
  THEN RAISE EXCEPTION 'GT05: cycle opening was not idempotent'; END IF;

  -- Clause 3: a second billing cycle for the same product must be refused.
  v_failed := FALSE;
  BEGIN
    PERFORM open_group_contribution_cycle(
      v_org, v_group, v_owner, v_product, '2026-10',
      DATE '2026-10-01', DATE '2026-10-31', DATE '2026-10-25', 'Africa/Lagos',
      '00000000-0000-4000-8000-000000000763', '2026-10-01T00:00:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CYCLE_ALREADY_BILLING%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a second concurrent cycle was allowed'; END IF;

  -- The GT-04 guard deferred to GT-05: superseding a rule mid-cycle is refused.
  v_proposal := create_group_proposal(v_org, v_group, v_owner, 'contribution_rule',
    'Raise the monthly due while a cycle is already billing against it.', '[]',
    jsonb_build_object(
      'action', 'supersede', 'product_id', v_product,
      'product_class', 'periodic_due', 'purpose', 'Raise the due',
      'amount_minor', 400000, 'currency', 'NGN',
      'permitted_rails', jsonb_build_array('paystack'),
      'refund_rule_code', 'NO_REFUND', 'revenue_account_code', 'DUES_INCOME'
    ), ARRAY[]::UUID[],
    '2026-09-05T10:00:00Z', '2026-09-05T11:00:00Z',
    '00000000-0000-4000-8000-000000000764', '2026-09-05T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000765', '2026-09-05T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000766', '2026-09-05T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000767', '2026-09-05T10:06:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000768', '2026-09-05T11:00:00Z');

  v_failed := FALSE;
  BEGIN
    PERFORM execute_group_contribution_rule_proposal(v_org, v_group, v_owner, v_proposal, 3,
      '00000000-0000-4000-8000-000000000769', '2026-09-05T11:01:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CYCLE_OPEN%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a rule was superseded while a cycle was billing'; END IF;

  -- Clause 4: an adjustment preserves the original expected amount.
  SELECT id INTO v_obligation FROM group_contribution_obligations
  WHERE cycle_id = v_cycle AND member_id = v_second_member;
  PERFORM adjust_group_contribution_obligation(
    v_org, v_group, v_owner, v_obligation, 'waiver', -250000, 'HARDSHIP',
    'Member hardship waiver approved by the committee.', '{}'::JSONB,
    '00000000-0000-4000-8000-000000000770', '2026-09-10T09:00:00Z');

  SELECT expected_minor, adjusted_minor, state
  INTO v_expected, v_adjusted, v_state
  FROM group_contribution_obligations WHERE id = v_obligation;
  IF v_expected <> 250000
  THEN RAISE EXCEPTION 'GT05: waiver rewrote the original expected amount'; END IF;
  IF v_adjusted <> -250000
  THEN RAISE EXCEPTION 'GT05: waiver delta was not recorded'; END IF;
  IF v_state <> 'waived'
  THEN RAISE EXCEPTION 'GT05: waived obligation is in state %', v_state; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_obligation_adjustments
    WHERE obligation_id = v_obligation AND original_expected_minor = 250000
      AND delta_minor = -250000 AND reason_code = 'HARDSHIP'
  ) THEN RAISE EXCEPTION 'GT05: adjustment evidence was not preserved'; END IF;

  -- Transition through grace: unpaid obligations become overdue.
  PERFORM transition_group_contribution_cycle(v_org, v_group, v_owner, v_cycle, 'grace',
    '00000000-0000-4000-8000-000000000771', '2026-09-26T00:00:00Z');
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_obligations
    WHERE cycle_id = v_cycle AND member_id = v_owner_member AND state = 'overdue'
  ) THEN RAISE EXCEPTION 'GT05: an unpaid obligation was not marked overdue'; END IF;
  -- A waived obligation is not overdue; it was settled by decision.
  IF EXISTS (
    SELECT 1 FROM group_contribution_obligations
    WHERE id = v_obligation AND state = 'overdue'
  ) THEN RAISE EXCEPTION 'GT05: a waived obligation was marked overdue'; END IF;

  -- Clause 7: the dashboard distinguishes the required figures and derives
  -- pending from expected minus received.
  v_dashboard := read_group_contribution_cycle_dashboard(v_org, v_group, v_owner, v_cycle);
  IF v_dashboard IS NULL THEN RAISE EXCEPTION 'GT05: dashboard returned nothing'; END IF;
  IF (v_dashboard->>'expected_minor')::BIGINT <> 250000 THEN
    RAISE EXCEPTION 'GT05: dashboard expected excludes waived, got %',
      v_dashboard->>'expected_minor';
  END IF;
  IF (v_dashboard->>'received_minor')::BIGINT <> 0
  THEN RAISE EXCEPTION 'GT05: dashboard reported unreceived money as received'; END IF;
  IF (v_dashboard->>'pending_minor')::BIGINT <> 250000
  THEN RAISE EXCEPTION 'GT05: dashboard pending is not expected minus received'; END IF;
  IF (v_dashboard->>'waived_minor')::BIGINT <> 0
  THEN RAISE EXCEPTION 'GT05: a fully waived obligation still shows a waived balance'; END IF;

  -- Close: exceptions must be acknowledged rather than passed over silently.
  PERFORM transition_group_contribution_cycle(v_org, v_group, v_owner, v_cycle, 'closing',
    '00000000-0000-4000-8000-000000000772', '2026-10-01T00:00:00Z');
  v_failed := FALSE;
  BEGIN
    PERFORM close_group_contribution_cycle(v_org, v_group, v_owner, v_cycle,
      'PERIOD_COMPLETE', FALSE, '00000000-0000-4000-8000-000000000773',
      '2026-10-02T00:00:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CYCLE_EXCEPTIONS_UNACKNOWLEDGED%'
    THEN v_failed := TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a cycle with open obligations closed silently'; END IF;

  -- Clause 6: a locked accounting period cannot absorb a close. It must be
  -- reopened deliberately rather than written through.
  UPDATE accounting_periods SET status = 'locked'
  WHERE organization_id = v_org AND starts_on = DATE '2026-09-01';
  v_failed := FALSE;
  BEGIN
    PERFORM close_group_contribution_cycle(v_org, v_group, v_owner, v_cycle,
      'PERIOD_COMPLETE', TRUE, '00000000-0000-4000-8000-000000000775',
      '2026-10-02T00:00:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_ACCOUNTING_PERIOD_CLOSED%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a cycle closed into a locked accounting period'; END IF;
  UPDATE accounting_periods SET status = 'open'
  WHERE organization_id = v_org AND starts_on = DATE '2026-09-01';

  PERFORM close_group_contribution_cycle(v_org, v_group, v_owner, v_cycle,
    'PERIOD_COMPLETE', TRUE, '00000000-0000-4000-8000-000000000774',
    '2026-10-02T00:00:00Z');
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_cycles
    WHERE id = v_cycle AND state = 'closed' AND exception_report IS NOT NULL
      AND close_reason_code = 'PERIOD_COMPLETE' AND accounting_period_id IS NOT NULL
  ) THEN RAISE EXCEPTION 'GT05: cycle did not close with its exception report'; END IF;

  -- Clause 6: closed-cycle financial records are immutable, even for the engine.
  v_failed := FALSE;
  BEGIN
    PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
    UPDATE group_contribution_obligations
    SET adjusted_minor = 0 WHERE cycle_id = v_cycle;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CYCLE_IMMUTABLE%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT05: a closed cycle''s obligations were rewritten'; END IF;

  RAISE NOTICE 'GT05 governed cycle lifecycle assertions passed';
END $$;

ROLLBACK;
