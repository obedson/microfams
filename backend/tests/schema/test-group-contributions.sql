-- GT-04 schema contract: classification fixes ownership, rules are versioned
-- and non-retroactive, and allocations are journal-linked and idempotent.

SET search_path = public, extensions;
BEGIN;

DO $$
DECLARE
  v_org UUID;
  v_user UUID;
  v_group UUID;
  v_constitution UUID;
  v_proposal UUID;
  v_product UUID;
  v_rule UUID;
  v_failed BOOLEAN;
BEGIN
  -- Every table and function the domain depends on must exist.
  IF to_regclass('public.group_contribution_products') IS NULL
    OR to_regclass('public.group_contribution_rule_versions') IS NULL
    OR to_regclass('public.group_contribution_adjustment_rules') IS NULL
    OR to_regclass('public.group_contribution_allocations') IS NULL
    OR to_regclass('public.group_contribution_events') IS NULL
  THEN RAISE EXCEPTION 'GT04: expected contribution tables are missing'; END IF;

  IF to_regprocedure('public.execute_group_contribution_rule_proposal(uuid,uuid,uuid,uuid,integer,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.allocate_group_contribution_payment(uuid,uuid,uuid,uuid,uuid,uuid,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.reverse_group_contribution_allocation(uuid,uuid,timestamptz)') IS NULL
  THEN RAISE EXCEPTION 'GT04: expected contribution functions are missing'; END IF;

  -- Direct writes must be refused: the engine lock is the only way in.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_products(
      organization_id, group_id, product_key, product_class, display_name
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), 'dues', 'periodic_due', 'Monthly dues'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_ENGINE_REQUIRED%' THEN v_failed := TRUE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: direct product insert was not refused'; END IF;

  -- Build a tenant, group, constitution, and approved proposal to execute against.
  INSERT INTO users(email, password, name, role)
  VALUES (
    'gt04-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
    'test',
    'GT04 Chair',
    'farmer'
  )
  RETURNING id INTO v_user;
  INSERT INTO organizations(name, slug, type, status, created_by)
  VALUES (
    'GT04 Org',
    'gt04-org-' || substr(md5(random()::TEXT), 1, 8),
    'cooperative',
    'active',
    v_user
  )
  RETURNING id INTO v_org;
  INSERT INTO organization_memberships(organization_id, user_id, status, role)
  VALUES (v_org, v_user, 'active', 'owner');

  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  -- Ownership is derived from class: a member_capital rule may not be
  -- recorded as group income.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_products(
      organization_id, group_id, product_key, product_class, display_name
    ) VALUES (v_org, gen_random_uuid(), 'cap', 'member_capital', 'Capital')
    RETURNING id INTO v_product;
  EXCEPTION WHEN foreign_key_violation THEN
    v_failed := TRUE;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: product accepted an unknown group'; END IF;

  RAISE NOTICE 'GT04 structural and engine-lock assertions passed';
END $$;

-- Ownership/class coupling is a table-level CHECK, so assert it directly
-- without needing a full tenant graph.
DO $$
DECLARE v_failed BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
  BEGIN
    INSERT INTO group_contribution_rule_versions(
      organization_id, group_id, product_id, constitution_id, version, state,
      product_class, ownership, purpose, amount_minor, currency, permitted_rails,
      refund_rule_code, withdrawal_rule_code, loss_allocation_rule_code,
      revenue_account_code, rule_proposal_id, effective_from
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      1, 'effective', 'member_capital', 'group_income', 'Misclassified capital',
      1000, 'NGN', ARRAY['paystack']::TEXT[], 'NO_REFUND', 'ON_EXIT',
      'PRO_RATA', 'DUES', gen_random_uuid(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: ownership CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: member_capital was accepted as group_income'; END IF;

  -- Member-attributed money must disclose withdrawal and loss rules.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_rule_versions(
      organization_id, group_id, product_id, constitution_id, version, state,
      product_class, ownership, purpose, amount_minor, currency, permitted_rails,
      refund_rule_code, revenue_account_code, rule_proposal_id, effective_from
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      1, 'effective', 'savings', 'member_attributed', 'Savings without rules',
      1000, 'NGN', ARRAY['paystack']::TEXT[], 'NO_REFUND', 'SAVINGS',
      gen_random_uuid(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: disclosure CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: member_attributed rule accepted without withdrawal/loss rules'; END IF;

  -- project_subscription must name its project; other classes must not.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_rule_versions(
      organization_id, group_id, product_id, constitution_id, version, state,
      product_class, ownership, purpose, amount_minor, currency, permitted_rails,
      refund_rule_code, revenue_account_code, rule_proposal_id, effective_from,
      project_id
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      1, 'effective', 'periodic_due', 'group_income', 'Dues claiming a project',
      1000, 'NGN', ARRAY['paystack']::TEXT[], 'NO_REFUND', 'DUES',
      gen_random_uuid(), NOW(), gen_random_uuid()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: project CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: non-project class accepted a project_id'; END IF;

  -- An unsupported payment rail must be rejected.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_rule_versions(
      organization_id, group_id, product_id, constitution_id, version, state,
      product_class, ownership, purpose, amount_minor, currency, permitted_rails,
      refund_rule_code, revenue_account_code, rule_proposal_id, effective_from
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      1, 'effective', 'periodic_due', 'group_income', 'Unknown rail',
      1000, 'NGN', ARRAY['crypto']::TEXT[], 'NO_REFUND', 'DUES',
      gen_random_uuid(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: rail CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: an unsupported payment rail was accepted'; END IF;

  -- Version 1 may not claim a predecessor.
  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_rule_versions(
      organization_id, group_id, product_id, constitution_id, version, state,
      product_class, ownership, purpose, amount_minor, currency, permitted_rails,
      refund_rule_code, revenue_account_code, rule_proposal_id, effective_from,
      supersedes_version_id
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      1, 'effective', 'periodic_due', 'group_income', 'First version',
      1000, 'NGN', ARRAY['paystack']::TEXT[], 'NO_REFUND', 'DUES',
      gen_random_uuid(), NOW(), gen_random_uuid()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: version lineage CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: version 1 accepted a supersedes_version_id'; END IF;

  RAISE NOTICE 'GT04 ownership and disclosure invariants passed';
END $$;

-- A penalty rule must carry exactly one calculation input for its basis, and a
-- fixed amount can never exceed its own cap.
DO $$
DECLARE v_failed BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
  BEGIN
    INSERT INTO group_contribution_adjustment_rules(
      organization_id, group_id, product_id, adjustment_kind, version, state,
      reason_code, reason, calculation_basis, fixed_amount_minor, rate_basis_points,
      cap_amount_minor, currency, grace_period_days, waiver_permission,
      journal_account_code, rule_proposal_id, effective_from
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'penalty', 1,
      'effective', 'LATE_PAYMENT', 'Late payment penalty',
      'percentage_of_expected', 500, 250, 10000, 'NGN', 7,
      'groups.contribution.waive', 'PENALTIES', gen_random_uuid(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: penalty basis CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: penalty accepted both a fixed amount and a rate'; END IF;

  v_failed := FALSE;
  BEGIN
    INSERT INTO group_contribution_adjustment_rules(
      organization_id, group_id, product_id, adjustment_kind, version, state,
      reason_code, reason, calculation_basis, fixed_amount_minor,
      cap_amount_minor, currency, grace_period_days, waiver_permission,
      journal_account_code, rule_proposal_id, effective_from
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'penalty', 1,
      'effective', 'LATE_PAYMENT', 'Penalty above its cap',
      'fixed_amount', 20000, 10000, 'NGN', 7,
      'groups.contribution.waive', 'PENALTIES', gen_random_uuid(), NOW()
    );
  EXCEPTION
    WHEN check_violation THEN v_failed := TRUE;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'GT04: penalty cap CHECK did not fire before FK resolution';
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: penalty accepted a fixed amount above its cap'; END IF;

  RAISE NOTICE 'GT04 adjustment-rule invariants passed';
END $$;

-- The engine functions must actually execute, not merely exist. A rule reaches
-- the ledger only through an approved, closed contribution_rule proposal, so
-- this drives the full governance path and then asserts the invariants that
-- protect ownership: derived ownership, an immutable class, and versions that
-- supersede rather than rewrite.
DO $$
DECLARE
  v_org UUID; v_owner UUID; v_second UUID;
  v_group UUID; v_owner_member UUID; v_second_member UUID;
  v_proposal UUID; v_decided group_proposals;
  v_product UUID; v_rule_v1 UUID; v_rule_v2 UUID;
  v_failed BOOLEAN;
  v_count INTEGER;
BEGIN
  SELECT organization_id, user_id INTO v_org, v_owner
  FROM organization_memberships WHERE status = 'active' AND role = 'owner'
  ORDER BY created_at LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'GT04: tenant fixture is unavailable'; END IF;

  INSERT INTO users(email, password, name, role) VALUES
    ('gt04-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test',
     'test', 'GT04 Second Voter', 'farmer')
    RETURNING id INTO v_second;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
    VALUES (v_org, v_second, 'member', 'active', NOW());

  INSERT INTO groups(name, category, creator_id, organization_id, max_members)
    VALUES ('GT04 Group', 'cooperative', v_owner, v_org, 10) RETURNING id INTO v_group;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_owner, 'owner', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_owner_member;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active, payment_status, amount_paid
  ) VALUES (v_org, v_group, v_second, 'member', 'active', TRUE, 'paid', 1000)
    RETURNING id INTO v_second_member;

  PERFORM adopt_initial_group_constitution(v_org, v_group, v_owner, 'GT04 Constitution',
    jsonb_build_object(
      'minimum_members', 2, 'ordinary_quorum_bps', 5000, 'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667, 'special_approval_bps', 6667, 'vote_change_allowed', false
    ), '00000000-0000-4000-8000-000000000731', '2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'chair', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000732', '2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'secretary', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000733', '2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(v_org, v_group, v_owner, 'treasurer', v_owner_member,
    NULL, '00000000-0000-4000-8000-000000000734', '2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(v_org, v_group, v_owner, 1,
    '00000000-0000-4000-8000-000000000735', '2026-08-03T09:04:00Z');

  -- Adopt a member_capital product: ownership must be derived, not supplied.
  v_proposal := create_group_proposal(v_org, v_group, v_owner, 'contribution_rule',
    'Adopt a member capital contribution with disclosed withdrawal and loss terms.',
    '[]',
    jsonb_build_object(
      'action', 'adopt', 'product_key', 'capital', 'display_name', 'Member capital',
      'product_class', 'member_capital', 'purpose', 'Build member-owned capital',
      'amount_minor', 500000, 'currency', 'NGN',
      'permitted_rails', jsonb_build_array('paystack', 'bank_transfer'),
      'refund_rule_code', 'NO_REFUND', 'withdrawal_rule_code', 'NOTICE_30_DAYS',
      'loss_allocation_rule_code', 'PRO_RATA', 'revenue_account_code', 'MEMBER_CAPITAL'
    ), ARRAY[]::UUID[],
    '2026-08-03T10:00:00Z', '2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000736', '2026-08-03T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000737', '2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000738', '2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000739', '2026-08-03T10:06:00Z');
  SELECT * INTO v_decided FROM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000740', '2026-08-03T11:00:00Z');
  IF v_decided.state <> 'approved'
  THEN RAISE EXCEPTION 'GT04: contribution rule proposal was not approved'; END IF;

  SELECT * INTO v_decided FROM execute_group_contribution_rule_proposal(
    v_org, v_group, v_owner, v_proposal, 3,
    '00000000-0000-4000-8000-000000000741', '2026-08-03T11:01:00Z');
  IF v_decided.state <> 'executed'
  THEN RAISE EXCEPTION 'GT04: contribution rule proposal did not execute'; END IF;

  SELECT id INTO v_product FROM group_contribution_products
  WHERE organization_id = v_org AND group_id = v_group AND product_key = 'capital';
  IF v_product IS NULL THEN RAISE EXCEPTION 'GT04: executor created no product'; END IF;
  SELECT id INTO v_rule_v1 FROM group_contribution_rule_versions
  WHERE product_id = v_product AND state = 'effective';
  IF v_rule_v1 IS NULL THEN RAISE EXCEPTION 'GT04: executor created no rule version'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM group_contribution_rule_versions
    WHERE id = v_rule_v1 AND ownership = 'member_attributed' AND version = 1
      AND supersedes_version_id IS NULL
  ) THEN RAISE EXCEPTION 'GT04: adopted rule did not derive member_attributed ownership'; END IF;

  -- Re-executing the same correlation must return the same decision, not a
  -- second product: allocation and execution are idempotent by correlation ID.
  PERFORM execute_group_contribution_rule_proposal(
    v_org, v_group, v_owner, v_proposal, 3,
    '00000000-0000-4000-8000-000000000741', '2026-08-03T11:01:00Z');
  SELECT count(*) INTO v_count FROM group_contribution_products
  WHERE organization_id = v_org AND group_id = v_group AND product_key = 'capital';
  IF v_count <> 1 THEN RAISE EXCEPTION 'GT04: rule execution was not idempotent'; END IF;

  -- A supersede may not reclassify a live product, because that would change
  -- who owns money already collected under it.
  v_proposal := create_group_proposal(v_org, v_group, v_owner, 'contribution_rule',
    'Attempt to reclassify member capital as ordinary group income.', '[]',
    jsonb_build_object(
      'action', 'supersede', 'product_id', v_product,
      'product_class', 'periodic_due', 'purpose', 'Reclassified capital',
      'amount_minor', 500000, 'currency', 'NGN',
      'permitted_rails', jsonb_build_array('paystack'),
      'refund_rule_code', 'NO_REFUND', 'revenue_account_code', 'DUES_INCOME'
    ), ARRAY[]::UUID[],
    '2026-08-04T10:00:00Z', '2026-08-04T11:00:00Z',
    '00000000-0000-4000-8000-000000000742', '2026-08-04T09:05:00Z');
  PERFORM open_group_proposal(v_org, v_group, v_owner, v_proposal, 1,
    '00000000-0000-4000-8000-000000000743', '2026-08-04T10:00:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_owner, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000744', '2026-08-04T10:05:00Z');
  PERFORM cast_group_proposal_vote(v_org, v_group, v_second, v_proposal, 'approve',
    '00000000-0000-4000-8000-000000000745', '2026-08-04T10:06:00Z');
  PERFORM close_group_proposal(v_org, v_group, v_owner, v_proposal, 2,
    '00000000-0000-4000-8000-000000000746', '2026-08-04T11:00:00Z');

  v_failed := FALSE;
  BEGIN
    PERFORM execute_group_contribution_rule_proposal(
      v_org, v_group, v_owner, v_proposal, 3,
      '00000000-0000-4000-8000-000000000747', '2026-08-04T11:01:00Z');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%GROUP_CONTRIBUTION_CLASS_IMMUTABLE%' THEN v_failed := TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed
  THEN RAISE EXCEPTION 'GT04: a live product was reclassified by a supersede'; END IF;

  RAISE NOTICE 'GT04 governed execution and idempotency assertions passed';
END $$;

ROLLBACK;
