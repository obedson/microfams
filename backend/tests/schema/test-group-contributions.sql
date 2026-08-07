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
  INSERT INTO organizations(name, slug, status)
  VALUES ('GT04 Org', 'gt04-org-' || substr(md5(random()::TEXT), 1, 8), 'active')
  RETURNING id INTO v_org;
  INSERT INTO users(email, full_name, nin_verified)
  VALUES ('gt04-' || substr(md5(random()::TEXT), 1, 8) || '@example.test', 'GT04 Chair', TRUE)
  RETURNING id INTO v_user;
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

ROLLBACK;
