-- GT-04: Contribution classification and ownership.
-- Every contribution product is classified and versioned before collection. The
-- product class fixes ownership, so no contribution can be represented as an
-- interchangeable group balance or silently recognized as income.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS group_contribution_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_key TEXT NOT NULL CHECK (product_key ~ '^[a-z][a-z0-9_]{1,47}$'),
  product_class TEXT NOT NULL CHECK (product_class IN (
    'membership_fee', 'periodic_due', 'member_capital',
    'project_subscription', 'savings'
  )),
  display_name TEXT NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 200),
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'retired')),
  retired_at TIMESTAMPTZ,
  retirement_reason_code TEXT CHECK (retirement_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((state = 'retired') = (retired_at IS NOT NULL)),
  CHECK ((state = 'retired') = (retirement_reason_code IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_contribution_product_key
  ON group_contribution_products(organization_id, group_id, product_key);
CREATE INDEX IF NOT EXISTS idx_group_contribution_products_tenant
  ON group_contribution_products(organization_id, group_id, state);

-- A rule version is immutable once effective. Amendments supersede; they never
-- rewrite. ownership is derived from product_class by CHECK so that a member's
-- capital or savings can never be reclassified as group income by an update.
CREATE TABLE IF NOT EXISTS group_contribution_rule_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL CHECK (version > 0),
  state TEXT NOT NULL CHECK (state IN ('effective', 'superseded')),
  product_class TEXT NOT NULL CHECK (product_class IN (
    'membership_fee', 'periodic_due', 'member_capital',
    'project_subscription', 'savings'
  )),
  ownership TEXT NOT NULL CHECK (ownership IN (
    'group_income', 'member_attributed', 'project_restricted'
  )),
  purpose TEXT NOT NULL CHECK (char_length(purpose) BETWEEN 1 AND 2000),
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0 AND amount_minor <= 100000000000),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  payer_eligibility JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(payer_eligibility) = 'object'),
  permitted_rails TEXT[] NOT NULL CHECK (
    array_length(permitted_rails, 1) BETWEEN 1 AND 8
    AND permitted_rails <@ ARRAY[
      'paystack', 'interswitch', 'bank_transfer', 'cash_evidence', 'internal_wallet'
    ]::TEXT[]
  ),
  due_schedule JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(due_schedule) = 'object'),
  refund_rule_code TEXT NOT NULL CHECK (refund_rule_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  withdrawal_rule_code TEXT CHECK (withdrawal_rule_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  loss_allocation_rule_code TEXT CHECK (loss_allocation_rule_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  revenue_account_code TEXT NOT NULL
    CHECK (revenue_account_code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  project_id UUID,
  rule_proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  effective_from TIMESTAMPTZ NOT NULL,
  superseded_at TIMESTAMPTZ,
  supersedes_version_id UUID REFERENCES group_contribution_rule_versions(id) ON DELETE RESTRICT,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_id, version),
  CHECK ((state = 'superseded') = (superseded_at IS NOT NULL)),
  CHECK (superseded_at IS NULL OR superseded_at >= effective_from),
  CHECK ((version = 1) = (supersedes_version_id IS NULL)),
  -- Ownership is a function of class, not an independent choice.
  CHECK (ownership = CASE product_class
    WHEN 'membership_fee' THEN 'group_income'
    WHEN 'periodic_due' THEN 'group_income'
    WHEN 'member_capital' THEN 'member_attributed'
    WHEN 'savings' THEN 'member_attributed'
    WHEN 'project_subscription' THEN 'project_restricted'
  END),
  -- Restricted funding names its project; nothing else may claim one.
  CHECK ((product_class = 'project_subscription') = (project_id IS NOT NULL)),
  -- Member-attributed money must disclose how it can be withdrawn and how
  -- losses land before anyone commits value to it.
  CHECK ((ownership = 'member_attributed') = (withdrawal_rule_code IS NOT NULL)),
  CHECK ((ownership = 'member_attributed') = (loss_allocation_rule_code IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_contribution_effective_rule
  ON group_contribution_rule_versions(product_id) WHERE state = 'effective';
CREATE INDEX IF NOT EXISTS idx_group_contribution_rules_tenant
  ON group_contribution_rule_versions(organization_id, group_id, state);
CREATE INDEX IF NOT EXISTS idx_group_contribution_rules_product
  ON group_contribution_rule_versions(product_id, version DESC);

-- Penalties and discounts are their own effective-dated, proposal-backed rules
-- with an explicit calculation basis, cap, grace period, waiver permission, and
-- journal mapping. A penalty is never silently netted from personal funds: it
-- is billed against the obligation and posted through its own account.
CREATE TABLE IF NOT EXISTS group_contribution_adjustment_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  adjustment_kind TEXT NOT NULL CHECK (adjustment_kind IN ('penalty', 'discount')),
  version INTEGER NOT NULL CHECK (version > 0),
  state TEXT NOT NULL CHECK (state IN ('effective', 'superseded')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  reason TEXT NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 1000),
  calculation_basis TEXT NOT NULL
    CHECK (calculation_basis IN ('fixed_amount', 'percentage_of_expected', 'per_day_overdue')),
  fixed_amount_minor BIGINT CHECK (fixed_amount_minor > 0),
  rate_basis_points INTEGER CHECK (rate_basis_points BETWEEN 1 AND 100000),
  cap_amount_minor BIGINT NOT NULL CHECK (cap_amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  grace_period_days INTEGER NOT NULL CHECK (grace_period_days BETWEEN 0 AND 365),
  waiver_permission TEXT NOT NULL
    CHECK (waiver_permission ~ '^[a-z][a-z0-9_.]{2,63}$'),
  journal_account_code TEXT NOT NULL
    CHECK (journal_account_code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  rule_proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  effective_from TIMESTAMPTZ NOT NULL,
  superseded_at TIMESTAMPTZ,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_id, adjustment_kind, version),
  CHECK ((state = 'superseded') = (superseded_at IS NOT NULL)),
  CHECK (superseded_at IS NULL OR superseded_at >= effective_from),
  -- Exactly one calculation input, matching the declared basis.
  CHECK ((calculation_basis = 'percentage_of_expected') = (rate_basis_points IS NOT NULL)),
  CHECK ((calculation_basis = 'percentage_of_expected') = (fixed_amount_minor IS NULL)),
  CHECK (fixed_amount_minor IS NULL OR fixed_amount_minor <= cap_amount_minor)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_contribution_effective_adjustment
  ON group_contribution_adjustment_rules(product_id, adjustment_kind)
  WHERE state = 'effective';
CREATE INDEX IF NOT EXISTS idx_group_contribution_adjustments_tenant
  ON group_contribution_adjustment_rules(organization_id, group_id, state);

-- Every confirmed contribution payment links one-to-one to the journal entry
-- that allocated it. The rule version is captured so the posting can always be
-- explained by the disclosed rule in force at the time of payment.
CREATE TABLE IF NOT EXISTS group_contribution_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  rule_version_id UUID NOT NULL
    REFERENCES group_contribution_rule_versions(id) ON DELETE RESTRICT,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  product_class TEXT NOT NULL,
  ownership TEXT NOT NULL CHECK (ownership IN (
    'group_income', 'member_attributed', 'project_restricted'
  )),
  payment_id UUID NOT NULL UNIQUE REFERENCES payments(id) ON DELETE RESTRICT,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'allocated' CHECK (state IN ('allocated', 'reversed')),
  allocation_journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
  reversal_id UUID UNIQUE REFERENCES payment_reversals(id),
  reversal_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  allocated_at TIMESTAMPTZ NOT NULL,
  reversed_at TIMESTAMPTZ,
  CHECK ((state = 'reversed') = (reversed_at IS NOT NULL)),
  CHECK ((state = 'reversed') = (reversal_journal_entry_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_allocations_tenant
  ON group_contribution_allocations(organization_id, group_id, product_id, state);
CREATE INDEX IF NOT EXISTS idx_group_contribution_allocations_member
  ON group_contribution_allocations(member_id, allocated_at DESC);

CREATE TABLE IF NOT EXISTS group_contribution_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_id UUID REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  resource_type TEXT NOT NULL CHECK (resource_type ~ '^[a-z][a-z0-9_]{2,63}$'),
  resource_id UUID NOT NULL,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  correlation_id UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_events_tenant
  ON group_contribution_events(organization_id, group_id, occurred_at DESC);

CREATE OR REPLACE FUNCTION protect_group_contribution_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_contribution_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'GROUP_CONTRIBUTION_ENGINE_REQUIRED';
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'group_contribution_products', 'group_contribution_rule_versions',
    'group_contribution_adjustment_rules', 'group_contribution_allocations',
    'group_contribution_events'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS protect_group_contribution_evidence ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER protect_group_contribution_evidence '
      'BEFORE INSERT OR UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION protect_group_contribution_evidence()', t
    );
  END LOOP;
END $$;

-- A contribution rule defines who owes what and who owns the money, so it is a
-- governance decision: it executes only from an approved, closed
-- contribution_rule proposal. Version 1 creates the product; later versions
-- supersede without rewriting history. Spec clause 4 forbids retroactive change
-- to an existing cycle; superseding is safe here because an allocation captures
-- the rule version that explained it. GT-05 introduces cycles and must add the
-- open-cycle guard to this executor when it does.
CREATE OR REPLACE FUNCTION execute_group_contribution_rule_proposal(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_proposal_id UUID,
  p_expected_version INTEGER,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS group_proposals
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_proposal group_proposals;
  v_group groups;
  v_product group_contribution_products;
  v_previous group_contribution_rule_versions;
  v_product_id UUID;
  v_rule_id UUID;
  v_action TEXT;
  v_product_key TEXT;
  v_product_class TEXT;
  v_ownership TEXT;
  v_amount_minor BIGINT;
  v_currency TEXT;
  v_rails TEXT[];
  v_project_id UUID;
  v_version INTEGER;
  v_previous_contribution TEXT;
  v_previous_proposal TEXT;
BEGIN
  SELECT proposal.* INTO v_proposal
  FROM group_proposal_events AS event
  JOIN group_proposals AS proposal ON proposal.id = event.proposal_id
  WHERE event.organization_id = p_organization_id
    AND event.correlation_id = p_correlation_id
    AND event.event_type = 'CONTRIBUTION_RULE_EXECUTED';
  IF FOUND THEN RETURN v_proposal; END IF;
  IF p_expected_version < 1 OR p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'active'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ACTIVE_GROUP_REQUIRED'; END IF;

  SELECT * INTO v_proposal FROM group_proposals
  WHERE id = p_proposal_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_PROPOSAL_NOT_FOUND'; END IF;
  IF v_proposal.state <> 'approved' OR v_proposal.state_version <> p_expected_version
  THEN RAISE EXCEPTION 'GROUP_PROPOSAL_VERSION_CONFLICT'; END IF;
  IF v_proposal.proposal_type <> 'contribution_rule'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PROPOSAL_TYPE_INVALID'; END IF;
  IF v_proposal.constitution_id <> v_group.current_constitution_id
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CONSTITUTION_CHANGED'; END IF;

  v_action := v_proposal.execution_payload->>'action';
  IF v_action NOT IN ('adopt', 'supersede')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYLOAD_INVALID'; END IF;

  v_product_class := v_proposal.execution_payload->>'product_class';
  IF v_product_class NOT IN (
    'membership_fee', 'periodic_due', 'member_capital',
    'project_subscription', 'savings'
  ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CLASS_INVALID'; END IF;
  v_ownership := CASE v_product_class
    WHEN 'membership_fee' THEN 'group_income'
    WHEN 'periodic_due' THEN 'group_income'
    WHEN 'member_capital' THEN 'member_attributed'
    WHEN 'savings' THEN 'member_attributed'
    WHEN 'project_subscription' THEN 'project_restricted'
  END;

  BEGIN
    v_amount_minor := (v_proposal.execution_payload->>'amount_minor')::BIGINT;
    v_project_id := NULLIF(v_proposal.execution_payload->>'project_id', '')::UUID;
    SELECT COALESCE(array_agg(value), '{}') INTO v_rails
    FROM jsonb_array_elements_text(
      COALESCE(v_proposal.execution_payload->'permitted_rails', '[]'::JSONB)
    ) AS value;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYLOAD_INVALID';
  END;
  v_currency := upper(COALESCE(v_proposal.execution_payload->>'currency', ''));
  IF v_amount_minor IS NULL OR v_amount_minor < 0 OR v_currency !~ '^[A-Z]{3}$'
    OR array_length(v_rails, 1) IS NULL
    OR NOT (v_rails <@ ARRAY[
      'paystack', 'interswitch', 'bank_transfer', 'cash_evidence', 'internal_wallet'
    ]::TEXT[])
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYLOAD_INVALID'; END IF;

  v_previous_contribution := current_setting('microfams.group_contribution_engine', TRUE);
  v_previous_proposal := current_setting('microfams.group_proposal_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_proposal_engine', 'on', TRUE);
  UPDATE group_proposals SET state = 'executing', state_version = state_version + 1,
    updated_at = p_occurred_at WHERE id = v_proposal.id;

  IF v_action = 'adopt' THEN
    v_product_key := v_proposal.execution_payload->>'product_key';
    IF v_product_key !~ '^[a-z][a-z0-9_]{1,47}$'
      OR COALESCE(v_proposal.execution_payload->>'display_name', '') = ''
    THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYLOAD_INVALID'; END IF;
    IF EXISTS (
      SELECT 1 FROM group_contribution_products
      WHERE organization_id = p_organization_id AND group_id = p_group_id
        AND product_key = v_product_key
    ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PRODUCT_KEY_CONFLICT'; END IF;
    INSERT INTO group_contribution_products(
      organization_id, group_id, product_key, product_class, display_name,
      state, created_by, created_at, updated_at
    ) VALUES (
      p_organization_id, p_group_id, v_product_key, v_product_class,
      v_proposal.execution_payload->>'display_name', 'active', p_actor_id,
      p_occurred_at, p_occurred_at
    ) RETURNING id INTO v_product_id;
    v_version := 1;
  ELSE
    BEGIN
      v_product_id := (v_proposal.execution_payload->>'product_id')::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYLOAD_INVALID';
    END;
    SELECT * INTO v_product FROM group_contribution_products
    WHERE id = v_product_id AND organization_id = p_organization_id
      AND group_id = p_group_id AND state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PRODUCT_NOT_ACTIVE'; END IF;
    -- Reclassifying a live product would change who owns money already collected.
    IF v_product.product_class <> v_product_class
    THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CLASS_IMMUTABLE'; END IF;
    SELECT * INTO v_previous FROM group_contribution_rule_versions
    WHERE product_id = v_product_id AND state = 'effective' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_RULE_NOT_EFFECTIVE'; END IF;
    UPDATE group_contribution_rule_versions
    SET state = 'superseded', superseded_at = p_occurred_at
    WHERE id = v_previous.id;
    v_version := v_previous.version + 1;
  END IF;

  INSERT INTO group_contribution_rule_versions(
    organization_id, group_id, product_id, constitution_id, version, state,
    product_class, ownership, purpose, amount_minor, currency, payer_eligibility,
    permitted_rails, due_schedule, refund_rule_code, withdrawal_rule_code,
    loss_allocation_rule_code, revenue_account_code, project_id, rule_proposal_id,
    effective_from, supersedes_version_id, created_by, created_at
  ) VALUES (
    p_organization_id, p_group_id, v_product_id, v_proposal.constitution_id,
    v_version, 'effective', v_product_class, v_ownership,
    v_proposal.execution_payload->>'purpose', v_amount_minor, v_currency,
    COALESCE(v_proposal.execution_payload->'payer_eligibility', '{}'::JSONB),
    v_rails, COALESCE(v_proposal.execution_payload->'due_schedule', '{}'::JSONB),
    v_proposal.execution_payload->>'refund_rule_code',
    NULLIF(v_proposal.execution_payload->>'withdrawal_rule_code', ''),
    NULLIF(v_proposal.execution_payload->>'loss_allocation_rule_code', ''),
    v_proposal.execution_payload->>'revenue_account_code', v_project_id,
    v_proposal.id, p_occurred_at, v_previous.id, p_actor_id, p_occurred_at
  ) RETURNING id INTO v_rule_id;

  UPDATE group_proposals SET state = 'executed', state_version = state_version + 1,
    result = COALESCE(result, '{}'::JSONB) || jsonb_build_object(
      'executed_resource_type', 'group_contribution_rule_version',
      'executed_resource_id', v_rule_id,
      'product_id', v_product_id,
      'product_class', v_product_class,
      'ownership', v_ownership,
      'version', v_version,
      'executed_at', p_occurred_at
    ), updated_at = p_occurred_at
  WHERE id = v_proposal.id RETURNING * INTO v_proposal;
  INSERT INTO group_proposal_events(
    organization_id, group_id, proposal_id, actor_id, event_type, from_state,
    to_state, resource_id, correlation_id, evidence, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_proposal.id, p_actor_id,
    'CONTRIBUTION_RULE_EXECUTED', 'approved', 'executed', v_rule_id,
    p_correlation_id,
    jsonb_build_object('product_id', v_product_id, 'version', v_version),
    p_occurred_at
  );
  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_product_id, 'contribution_rule_version',
    v_rule_id, p_actor_id,
    CASE WHEN v_action = 'adopt' THEN 'CONTRIBUTION_RULE_ADOPTED'
      ELSE 'CONTRIBUTION_RULE_SUPERSEDED' END,
    jsonb_build_object(
      'product_class', v_product_class, 'ownership', v_ownership,
      'amount_minor', v_amount_minor, 'currency', v_currency,
      'version', v_version, 'proposal_id', v_proposal.id
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous_contribution, ''), TRUE);
  PERFORM set_config('microfams.group_proposal_engine', COALESCE(v_previous_proposal, ''), TRUE);
  RETURN v_proposal;
END;
$$;

-- Confirmation and allocation are one transaction (spec clause 7). The credit
-- side is chosen by ownership, which is what keeps member capital and savings
-- off the group's income and out of a single interchangeable balance:
--   group_income      -> group revenue account
--   member_attributed -> member equity liability account (owed back to member)
--   project_restricted-> restricted project liability account
CREATE OR REPLACE FUNCTION allocate_group_contribution_payment(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_member_id UUID,
  p_product_id UUID,
  p_payment_id UUID,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_allocation group_contribution_allocations;
  v_rule group_contribution_rule_versions;
  v_member group_members;
  v_payment payments;
  v_allocation_id UUID;
  v_customer UUID;
  v_credit UUID;
  v_group_key TEXT;
  v_journal UUID;
  v_lines JSONB;
  v_previous_setting TEXT;
BEGIN
  SELECT resource_id INTO v_allocation_id FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_PAYMENT_ALLOCATED';
  IF FOUND THEN RETURN v_allocation_id; END IF;
  SELECT * INTO v_allocation FROM group_contribution_allocations
  WHERE payment_id = p_payment_id;
  IF FOUND THEN RETURN v_allocation.id; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  SELECT * INTO v_member FROM group_members
  WHERE id = p_member_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND status = 'active'
    AND is_active = TRUE FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_ACTIVE_MEMBER_REQUIRED'; END IF;

  SELECT * INTO v_rule FROM group_contribution_rule_versions
  WHERE product_id = p_product_id AND organization_id = p_organization_id
    AND group_id = p_group_id AND state = 'effective';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_RULE_NOT_EFFECTIVE'; END IF;
  IF v_rule.effective_from > p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_RULE_NOT_YET_EFFECTIVE'; END IF;

  -- Verify the payment server-side; never trust a client-reported success.
  -- source_type 'contribution' is the value permitted by the payment engine.
  SELECT * INTO v_payment FROM payments
  WHERE id = p_payment_id AND organization_id = p_organization_id
    AND source_type = 'contribution' AND source_id = p_product_id
    AND payer_id = v_member.user_id AND state = 'succeeded'
    AND success_journal_entry_id IS NOT NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYMENT_UNVERIFIED'; END IF;
  IF v_payment.currency <> v_rule.currency
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYMENT_MISMATCH'; END IF;
  -- Partial and excess payments are permitted (clause 5); a zero or negative
  -- allocation is not.
  IF v_payment.amount_minor <= 0
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_PAYMENT_MISMATCH'; END IF;

  v_group_key := upper(substr(md5(p_group_id::TEXT), 1, 16));
  v_customer := ensure_wallet_system_account(
    p_organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  IF v_rule.ownership = 'group_income' THEN
    v_credit := ensure_wallet_system_account(
      p_organization_id, 'GROUP.' || v_group_key || '.' || v_rule.revenue_account_code,
      'Group contribution income', 'revenue', 'credit'
    );
  ELSIF v_rule.ownership = 'member_attributed' THEN
    -- A liability: the group owes this value back to the member under the
    -- disclosed withdrawal rule. It is not group income and not spendable
    -- as a general balance.
    v_credit := ensure_wallet_system_account(
      p_organization_id, 'GROUP.' || v_group_key || '.MEMBER_CAPITAL',
      'Member-attributed contribution capital', 'liability', 'credit'
    );
  ELSE
    v_credit := ensure_wallet_system_account(
      p_organization_id, 'GROUP.' || v_group_key || '.PROJECT_RESTRICTED',
      'Restricted project subscription funding', 'liability', 'credit'
    );
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_customer, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_payment.amount_minor,
      'memo', 'Allocate verified group contribution'
    ),
    jsonb_build_object(
      'account_id', v_credit, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_payment.amount_minor,
      'memo', 'Recognize ' || v_rule.ownership || ' contribution'
    )
  );
  v_journal := post_wallet_journal(
    p_organization_id, 'group.contribution', v_payment.id::TEXT,
    'Allocate verified group contribution', v_lines
  );

  v_previous_setting := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
  INSERT INTO group_contribution_allocations(
    organization_id, group_id, product_id, rule_version_id, member_id, user_id,
    product_class, ownership, payment_id, amount_minor, currency, state,
    allocation_journal_entry_id, allocated_at
  ) VALUES (
    p_organization_id, p_group_id, p_product_id, v_rule.id, v_member.id,
    v_member.user_id, v_rule.product_class, v_rule.ownership, v_payment.id,
    v_payment.amount_minor, v_payment.currency, 'allocated', v_journal, p_occurred_at
  ) RETURNING id INTO v_allocation_id;
  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_product_id, 'contribution_allocation',
    v_allocation_id, p_actor_id, 'CONTRIBUTION_PAYMENT_ALLOCATED',
    jsonb_build_object(
      'payment_id', v_payment.id, 'journal_entry_id', v_journal,
      'amount_minor', v_payment.amount_minor, 'currency', v_payment.currency,
      'ownership', v_rule.ownership, 'rule_version_id', v_rule.id
    ), p_correlation_id, p_occurred_at
  );
  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_allocation_id;
END;
$$;

CREATE OR REPLACE FUNCTION reverse_group_contribution_allocation(
  p_payment_id UUID,
  p_reversal_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_allocation group_contribution_allocations;
  v_reversal payment_reversals;
  v_rule group_contribution_rule_versions;
  v_customer UUID;
  v_credit UUID;
  v_group_key TEXT;
  v_journal UUID;
  v_lines JSONB;
  v_previous_setting TEXT;
BEGIN
  SELECT * INTO v_allocation FROM group_contribution_allocations
  WHERE payment_id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ALLOCATION_NOT_FOUND'; END IF;
  IF v_allocation.state = 'reversed' THEN RETURN v_allocation.id; END IF;
  SELECT * INTO v_reversal FROM payment_reversals
  WHERE id = p_reversal_id AND payment_id = p_payment_id
    AND amount_minor = v_allocation.amount_minor;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_REVERSAL_UNVERIFIED'; END IF;
  SELECT * INTO v_rule FROM group_contribution_rule_versions
  WHERE id = v_allocation.rule_version_id;

  v_group_key := upper(substr(md5(v_allocation.group_id::TEXT), 1, 16));
  v_customer := ensure_wallet_system_account(
    v_allocation.organization_id, 'PAYMENT.CUSTOMER_FUNDS',
    'Inbound customer funds pending allocation', 'liability', 'credit'
  );
  IF v_allocation.ownership = 'group_income' THEN
    v_credit := ensure_wallet_system_account(
      v_allocation.organization_id,
      'GROUP.' || v_group_key || '.' || v_rule.revenue_account_code,
      'Group contribution income', 'revenue', 'credit'
    );
  ELSIF v_allocation.ownership = 'member_attributed' THEN
    v_credit := ensure_wallet_system_account(
      v_allocation.organization_id, 'GROUP.' || v_group_key || '.MEMBER_CAPITAL',
      'Member-attributed contribution capital', 'liability', 'credit'
    );
  ELSE
    v_credit := ensure_wallet_system_account(
      v_allocation.organization_id, 'GROUP.' || v_group_key || '.PROJECT_RESTRICTED',
      'Restricted project subscription funding', 'liability', 'credit'
    );
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_credit, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_allocation.amount_minor,
      'memo', 'Reverse ' || v_allocation.ownership || ' contribution'
    ),
    jsonb_build_object(
      'account_id', v_customer, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_allocation.amount_minor,
      'memo', 'Restore customer funds allocation'
    )
  );
  v_journal := post_wallet_journal(
    v_allocation.organization_id, 'group.contribution_reversal',
    v_reversal.id::TEXT, 'Reverse group contribution allocation', v_lines
  );

  v_previous_setting := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);
  UPDATE group_contribution_allocations
  SET state = 'reversed', reversal_id = v_reversal.id,
    reversal_journal_entry_id = v_journal, reversed_at = p_occurred_at
  WHERE id = v_allocation.id;
  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    v_allocation.organization_id, v_allocation.group_id, v_allocation.product_id,
    'contribution_allocation', v_allocation.id, NULL,
    'CONTRIBUTION_PAYMENT_REVERSED',
    jsonb_build_object(
      'payment_id', p_payment_id, 'reversal_id', v_reversal.id,
      'journal_entry_id', v_journal
    ), v_reversal.id, p_occurred_at
  );
  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous_setting, ''), TRUE);
  RETURN v_allocation.id;
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'group_contribution_products', 'group_contribution_rule_versions',
    'group_contribution_adjustment_rules', 'group_contribution_allocations',
    'group_contribution_events'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', t);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT '
      'USING (has_active_organization_membership(organization_id))', t
    );
    EXECUTE format('REVOKE ALL ON %I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON %I TO service_role', t);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I FROM service_role', t);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION execute_group_contribution_rule_proposal(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION allocate_group_contribution_payment(
  UUID, UUID, UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION reverse_group_contribution_allocation(
  UUID, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION execute_group_contribution_rule_proposal(
  UUID, UUID, UUID, UUID, INTEGER, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION allocate_group_contribution_payment(
  UUID, UUID, UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION reverse_group_contribution_allocation(
  UUID, UUID, TIMESTAMPTZ
) TO service_role;





