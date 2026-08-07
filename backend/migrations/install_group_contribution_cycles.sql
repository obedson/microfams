-- GT-05: group contribution cycles, per-member obligations, and reconciliation.
--
-- A cycle is the period in which a disclosed contribution rule is actually
-- billed. Spec clause 1 requires a cycle to bind one immutable rule version, so
-- the rule that explained an obligation can never be swapped out from under it.
-- Clause 4 forbids retroactive change: an obligation's original amount is
-- preserved forever and every later change is a separate evidenced adjustment
-- row carrying its own reason. Clause 5 forbids excess value silently becoming
-- group income, so overpayment lands in an explicit disposition queue instead of
-- being absorbed. Clause 7 requires dashboard money to derive from posted
-- journals rather than from counters maintained beside them.
--
-- This migration also installs the open-cycle guard that GT-04 deferred: a rule
-- version may not be superseded while a cycle is billing against it.

-- One cycle binds one rule version for one period. The rule version, currency,
-- and expected total are captured at open time and never recomputed, so the
-- cycle remains explainable after the product's rule moves on.
CREATE TABLE IF NOT EXISTS group_contribution_cycles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  rule_version_id UUID NOT NULL
    REFERENCES group_contribution_rule_versions(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  period_key TEXT NOT NULL CHECK (period_key ~ '^[0-9]{4}(-[0-9]{2}){0,2}$'),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  timezone TEXT NOT NULL CHECK (char_length(timezone) BETWEEN 3 AND 64),
  due_date DATE NOT NULL,
  grace_end_date DATE NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN (
    'draft', 'open', 'grace', 'closing', 'closed', 'cancelled'
  )),
  expected_total_minor BIGINT NOT NULL DEFAULT 0
    CHECK (expected_total_minor >= 0 AND expected_total_minor <= 100000000000),
  obligation_count INTEGER NOT NULL DEFAULT 0 CHECK (obligation_count >= 0),
  -- Clause 1: the member eligibility snapshot the obligations were generated
  -- from. Kept as evidence so a later membership change cannot make the
  -- original billing look wrong in hindsight.
  eligibility_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(eligibility_snapshot) = 'object'),
  accounting_period_id UUID REFERENCES accounting_periods(id) ON DELETE RESTRICT,
  opened_at TIMESTAMPTZ,
  grace_started_at TIMESTAMPTZ,
  closing_started_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  close_reason_code TEXT CHECK (close_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  cancellation_reason_code TEXT CHECK (cancellation_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  cancellation_reason TEXT
    CHECK (cancellation_reason IS NULL
      OR char_length(cancellation_reason) BETWEEN 1 AND 1000),
  -- The completion and exception figures the closer was shown, frozen onto the
  -- cycle at close so the basis of the decision survives with it (clause 6).
  exception_report JSONB,
  opened_by UUID REFERENCES users(id) ON DELETE SET NULL,
  closed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_id, period_key),
  UNIQUE (id, organization_id, group_id),
  CHECK (period_end >= period_start),
  CHECK (due_date >= period_start),
  CHECK (grace_end_date >= due_date),
  -- Timestamps are monotonic milestones, not state flags: a closing cycle that
  -- passed through grace keeps its grace_started_at. So each milestone is
  -- constrained by which states may carry it, and which states require it.
  CHECK (state <> 'draft' OR opened_at IS NULL),
  CHECK (state IN ('draft', 'cancelled') OR opened_at IS NOT NULL),
  CHECK (grace_started_at IS NULL OR state IN ('grace', 'closing', 'closed', 'cancelled')),
  CHECK (state <> 'grace' OR grace_started_at IS NOT NULL),
  CHECK (closing_started_at IS NULL OR state IN ('closing', 'closed', 'cancelled')),
  CHECK (state <> 'closing' OR closing_started_at IS NOT NULL),
  CHECK ((state = 'closed') = (closed_at IS NOT NULL)),
  CHECK ((state = 'closed') = (close_reason_code IS NOT NULL)),
  CHECK ((state = 'cancelled') = (cancelled_at IS NOT NULL)),
  CHECK ((state = 'cancelled') = (cancellation_reason_code IS NOT NULL)),
  -- Closing is an accounting act, so a closed cycle names the period it landed
  -- in. Clause 6 makes that period's own state the gate.
  CHECK ((state = 'closed') = (accounting_period_id IS NOT NULL))
);
-- Clause 3: at most one cycle may be billing per product at a time unless the
-- constitution permits overlap, which the opener checks before inserting.
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_contribution_cycle_billing
  ON group_contribution_cycles(product_id)
  WHERE state IN ('open', 'grace', 'closing');
CREATE INDEX IF NOT EXISTS idx_group_contribution_cycles_tenant
  ON group_contribution_cycles(organization_id, group_id, state, due_date DESC);
CREATE INDEX IF NOT EXISTS idx_group_contribution_cycles_rule
  ON group_contribution_cycles(rule_version_id, state);

-- An obligation is generated once at open from the active-membership snapshot.
-- expected_minor is immutable: it records what the member owed when the cycle
-- opened. A later change (waiver, reduction, correction) is an adjustment row
-- that preserves the original amount, the delta, and the reason, so the history
-- of every obligation is auditable end to end.
CREATE TABLE IF NOT EXISTS group_contribution_obligations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  cycle_id UUID NOT NULL REFERENCES group_contribution_cycles(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES group_contribution_products(id) ON DELETE RESTRICT,
  rule_version_id UUID NOT NULL
    REFERENCES group_contribution_rule_versions(id) ON DELETE RESTRICT,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  expected_minor BIGINT NOT NULL CHECK (expected_minor > 0 AND expected_minor <= 100000000000),
  -- Sum of the completed adjustments; the amount actually owed.
  adjusted_minor BIGINT NOT NULL DEFAULT 0
    CHECK (adjusted_minor >= -expected_minor AND adjusted_minor <= 100000000000),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN (
    'open', 'satisfied', 'excess', 'waived', 'overdue', 'written_off'
  )),
  satisfied_at TIMESTAMPTZ,
  waived_at TIMESTAMPTZ,
  written_off_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cycle_id, member_id),
  UNIQUE (id, organization_id, group_id),
  -- A full waiver or write-off legitimately brings the amount owed to zero
  -- (clause 4), so zero is valid; only a negative balance is not.
  CHECK (expected_minor + adjusted_minor >= 0)
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_obligations_cycle
  ON group_contribution_obligations(cycle_id, member_id);
CREATE INDEX IF NOT EXISTS idx_group_contribution_obligations_member
  ON group_contribution_obligations(member_id, cycle_id);

-- Every change to an obligation is its own immutable, evidenced row. The
-- original amount and the delta are preserved, so no adjustment can silently
-- rewrite what a member owed.
CREATE TABLE IF NOT EXISTS group_contribution_obligation_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  cycle_id UUID NOT NULL REFERENCES group_contribution_cycles(id) ON DELETE RESTRICT,
  obligation_id UUID NOT NULL
    REFERENCES group_contribution_obligations(id) ON DELETE RESTRICT,
  adjustment_kind TEXT NOT NULL
    CHECK (adjustment_kind IN ('waiver', 'reduction', 'correction', 'write_off')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  reason TEXT NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 1000),
  delta_minor BIGINT NOT NULL CHECK (delta_minor <> 0 AND abs(delta_minor) <= 100000000000),
  -- The obligation's expected_minor at the moment of the adjustment, so the
  -- event can always be explained against the snapshot it was computed from.
  original_expected_minor BIGINT NOT NULL CHECK (original_expected_minor > 0),
  applied_to_state TEXT NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_adjustments_obligation
  ON group_contribution_obligation_adjustments(obligation_id, created_at);

-- One row per allocation applied to an obligation. This is the join that lets
-- collected-to-date be derived from posted allocations (clause 7) instead of
-- from a counter kept beside them: a reversed allocation drops out of the sum
-- automatically because the sum reads allocation.state.
CREATE TABLE IF NOT EXISTS group_contribution_settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  cycle_id UUID NOT NULL REFERENCES group_contribution_cycles(id) ON DELETE RESTRICT,
  obligation_id UUID NOT NULL
    REFERENCES group_contribution_obligations(id) ON DELETE RESTRICT,
  allocation_id UUID NOT NULL UNIQUE
    REFERENCES group_contribution_allocations(id) ON DELETE RESTRICT,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  applied_minor BIGINT NOT NULL CHECK (applied_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  settled_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_settlements_obligation
  ON group_contribution_settlements(obligation_id, settled_at);
CREATE INDEX IF NOT EXISTS idx_group_contribution_settlements_cycle
  ON group_contribution_settlements(cycle_id);

-- Clause 5: a payment may exceed the obligation. The excess is not silently
-- absorbed into income; it is parked here and applied by an explicit, evidenced
-- disposition command, or refunded. An unreconciled excess row is exactly the
-- kind of open item a dashboard must surface rather than hide.
CREATE TABLE IF NOT EXISTS group_contribution_excess_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  cycle_id UUID NOT NULL REFERENCES group_contribution_cycles(id) ON DELETE RESTRICT,
  obligation_id UUID NOT NULL
    REFERENCES group_contribution_obligations(id) ON DELETE RESTRICT,
  allocation_id UUID NOT NULL UNIQUE
    REFERENCES group_contribution_allocations(id) ON DELETE RESTRICT,
  member_id UUID NOT NULL REFERENCES group_members(id) ON DELETE RESTRICT,
  excess_minor BIGINT NOT NULL CHECK (excess_minor > 0),
  disposition TEXT NOT NULL DEFAULT 'unreconciled' CHECK (disposition IN (
    'unreconciled', 'applied_to_next', 'refunded'
  )),
  applied_to_cycle_id UUID REFERENCES group_contribution_cycles(id) ON DELETE RESTRICT,
  refunded_at TIMESTAMPTZ,
  decision_reason_code TEXT CHECK (decision_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (id, organization_id, group_id),
  CHECK (disposition = 'refunded' OR refunded_at IS NULL)
);
CREATE INDEX IF NOT EXISTS idx_group_contribution_excess_unreconciled
  ON group_contribution_excess_payments(organization_id, cycle_id)
  WHERE disposition = 'unreconciled';

-- The same evidence-protection trigger pattern: no direct writes into cycle
-- tables; every state change arrives through an engine function.
CREATE OR REPLACE FUNCTION protect_group_contribution_cycle_evidence() RETURNS TRIGGER
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
    'group_contribution_cycles', 'group_contribution_obligations',
    'group_contribution_obligation_adjustments', 'group_contribution_excess_payments'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS protect_group_contribution_cycle_evidence ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER protect_group_contribution_cycle_evidence '
      'BEFORE INSERT OR UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION protect_group_contribution_cycle_evidence()', t
    );
  END LOOP;
END $$;

-- The GT-04 guard deferred to GT-05: spec clause 4 forbids retroactive change to
-- an existing cycle, so a rule version may not be superseded while a cycle is
-- billing against it. This is recreated here (after the cycle tables exist)
-- with the guard inside; it must stay in sync with the GT-04 executor.
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
  v_open_cycle TEXT;
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
    -- GT-05: clause 4 forbids retroactive change to an existing cycle. A
    -- supersede would not rewrite history, but it would silently re-bill an
    -- open cycle under terms the members did not approve for it, so refuse
    -- while any cycle is billing against this rule.
    SELECT state INTO v_open_cycle FROM group_contribution_cycles
    WHERE product_id = v_product_id AND state IN ('open', 'grace', 'closing')
    LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_OPEN'; END IF;
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

-- Opening a cycle binds the rule version in force right now and generates one
-- obligation per active member from that snapshot. Clause 3 allows a second
-- concurrent cycle only where the constitution says so; otherwise the partial
-- unique index refuses it. Obligation generation happens inside this same
-- transaction, so a cycle never exists in a billing state without its
-- obligations.
CREATE OR REPLACE FUNCTION open_group_contribution_cycle(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_product_id UUID,
  p_period_key TEXT,
  p_period_start DATE,
  p_period_end DATE,
  p_due_date DATE,
  p_timezone TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group groups;
  v_rule group_contribution_rule_versions;
  v_constitution group_constitutions;
  v_cycle_id UUID;
  v_grace_days INTEGER;
  v_allow_overlap BOOLEAN;
  v_expected BIGINT;
  v_count INTEGER;
  v_snapshot JSONB;
  v_previous TEXT;
BEGIN
  SELECT resource_id INTO v_cycle_id FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_CYCLE_OPENED';
  IF FOUND THEN RETURN v_cycle_id; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL OR p_period_key IS NULL
    OR p_period_start IS NULL OR p_period_end IS NULL OR p_due_date IS NULL
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;
  IF p_timezone IS NULL OR char_length(p_timezone) NOT BETWEEN 3 AND 64
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);
  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state <> 'active'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ACTIVE_GROUP_REQUIRED'; END IF;

  -- Clause 1: bind the rule version that is effective now, and lock it so a
  -- concurrent supersede cannot slip between this read and the insert.
  SELECT rule.* INTO v_rule FROM group_contribution_rule_versions AS rule
  JOIN group_contribution_products AS product ON product.id = rule.product_id
  WHERE rule.product_id = p_product_id
    AND rule.organization_id = p_organization_id
    AND rule.group_id = p_group_id
    AND rule.state = 'effective'
    AND product.state = 'active'
  FOR UPDATE OF rule;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_RULE_NOT_EFFECTIVE'; END IF;
  IF v_rule.amount_minor = 0
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_AMOUNT_NOT_BILLABLE'; END IF;

  SELECT * INTO v_constitution FROM group_constitutions
  WHERE id = v_group.current_constitution_id AND group_id = p_group_id
    AND status = 'effective';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONSTITUTION_NOT_EFFECTIVE'; END IF;
  IF v_rule.constitution_id <> v_constitution.id
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CONSTITUTION_CHANGED'; END IF;

  v_allow_overlap := COALESCE(
    (v_constitution.rules #>> '{contributions,allow_concurrent_cycles}')::BOOLEAN, FALSE
  );
  IF NOT v_allow_overlap AND EXISTS (
    SELECT 1 FROM group_contribution_cycles
    WHERE product_id = p_product_id AND state IN ('open', 'grace', 'closing')
  ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_ALREADY_BILLING'; END IF;

  v_grace_days := GREATEST(COALESCE(
    (v_rule.due_schedule #>> '{grace_period_days}')::INTEGER, 0
  ), 0);

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  INSERT INTO group_contribution_cycles(
    organization_id, group_id, product_id, rule_version_id, constitution_id,
    period_key, period_start, period_end, timezone, due_date, grace_end_date,
    currency, state, opened_at, opened_by, created_at, updated_at
  ) VALUES (
    p_organization_id, p_group_id, p_product_id, v_rule.id, v_constitution.id,
    p_period_key, p_period_start, p_period_end, p_timezone, p_due_date,
    p_due_date + v_grace_days, v_rule.currency, 'open', p_occurred_at, p_actor_id,
    p_occurred_at, p_occurred_at
  ) RETURNING id INTO v_cycle_id;

  -- Clause 2: obligations come from the active-membership snapshot at open.
  -- Suspended and expelled members are not billed.
  INSERT INTO group_contribution_obligations(
    organization_id, group_id, cycle_id, product_id, rule_version_id,
    member_id, user_id, expected_minor, state, created_at, updated_at
  )
  SELECT p_organization_id, p_group_id, v_cycle_id, p_product_id, v_rule.id,
    member.id, member.user_id, v_rule.amount_minor, 'open', p_occurred_at, p_occurred_at
  FROM group_members AS member
  WHERE member.group_id = p_group_id
    AND member.organization_id = p_organization_id
    AND member.status = 'active'
    AND member.is_active IS TRUE;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_NO_ACTIVE_MEMBERS'; END IF;
  v_expected := v_count::BIGINT * v_rule.amount_minor;

  -- Freeze who was billed and at what amount, as of this instant.
  SELECT jsonb_build_object(
    'captured_at', p_occurred_at,
    'rule_version_id', v_rule.id,
    'amount_minor', v_rule.amount_minor,
    'members', COALESCE(jsonb_agg(
      jsonb_build_object('member_id', member_id, 'user_id', user_id,
        'expected_minor', expected_minor) ORDER BY member_id
    ), '[]'::JSONB)
  ) INTO v_snapshot
  FROM group_contribution_obligations WHERE cycle_id = v_cycle_id;

  UPDATE group_contribution_cycles
  SET expected_total_minor = v_expected, obligation_count = v_count,
    eligibility_snapshot = v_snapshot, updated_at = p_occurred_at
  WHERE id = v_cycle_id;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, p_product_id, 'contribution_cycle',
    v_cycle_id, p_actor_id, 'CONTRIBUTION_CYCLE_OPENED',
    jsonb_build_object(
      'rule_version_id', v_rule.id, 'period_key', p_period_key,
      'obligation_count', v_count, 'expected_total_minor', v_expected,
      'currency', v_rule.currency, 'due_date', p_due_date,
      'grace_end_date', p_due_date + v_grace_days
    ), p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_cycle_id;
END;
$$;

-- Settlement links a GT-04 allocation to the obligation it satisfies. The
-- allocation already posted the journal entry and credited by ownership; this
-- function does not touch money. It reconciles: it decides whether the
-- obligation is now satisfied, and if the payment exceeded what was owed, it
-- parks the excess for an explicit disposition rather than letting it drift into
-- group income (clause 5).
CREATE OR REPLACE FUNCTION settle_group_contribution_obligation(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_obligation_id UUID,
  p_allocation_id UUID,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_obligation group_contribution_obligations;
  v_cycle group_contribution_cycles;
  v_allocation group_contribution_allocations;
  v_settled BIGINT;
  v_owed BIGINT;
  v_excess BIGINT;
  v_state TEXT;
  v_existing UUID;
  v_previous TEXT;
BEGIN
  SELECT resource_id INTO v_existing FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_OBLIGATION_SETTLED';
  IF FOUND THEN RETURN v_existing; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  SELECT * INTO v_obligation FROM group_contribution_obligations
  WHERE id = p_obligation_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_OBLIGATION_NOT_FOUND'; END IF;
  IF v_obligation.state IN ('waived', 'written_off')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_OBLIGATION_NOT_PAYABLE'; END IF;

  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = v_obligation.cycle_id FOR UPDATE;
  IF v_cycle.state NOT IN ('open', 'grace', 'closing')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_NOT_BILLING'; END IF;

  SELECT * INTO v_allocation FROM group_contribution_allocations
  WHERE id = p_allocation_id AND organization_id = p_organization_id
    AND group_id = p_group_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ALLOCATION_NOT_FOUND'; END IF;
  IF v_allocation.state <> 'allocated'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ALLOCATION_NOT_ACTIVE'; END IF;
  -- The allocation must belong to the same member, product, and rule version the
  -- obligation was billed under, or it is explaining a different debt.
  IF v_allocation.member_id <> v_obligation.member_id
    OR v_allocation.product_id <> v_obligation.product_id
    OR v_allocation.rule_version_id <> v_obligation.rule_version_id
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ALLOCATION_MISMATCH'; END IF;
  IF v_allocation.currency <> v_cycle.currency
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CURRENCY_MISMATCH'; END IF;
  IF EXISTS (
    SELECT 1 FROM group_contribution_settlements
    WHERE allocation_id = p_allocation_id
  ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ALLOCATION_ALREADY_SETTLED'; END IF;

  -- Clause 7: what has been settled is derived from the live allocation rows,
  -- not from a counter on the cycle. Reversed allocations drop out by state.
  SELECT COALESCE(sum(allocation.amount_minor), 0) INTO v_settled
  FROM group_contribution_settlements AS settlement
  JOIN group_contribution_allocations AS allocation
    ON allocation.id = settlement.allocation_id
  WHERE settlement.obligation_id = p_obligation_id AND allocation.state = 'allocated';

  v_owed := v_obligation.expected_minor + v_obligation.adjusted_minor;
  v_excess := GREATEST(v_settled + v_allocation.amount_minor - v_owed, 0);
  -- A part-payment does not clear a late debt: an already-overdue obligation
  -- stays overdue until it is actually satisfied.
  v_state := CASE
    WHEN v_excess > 0 THEN 'excess'
    WHEN v_settled + v_allocation.amount_minor >= v_owed THEN 'satisfied'
    WHEN v_obligation.state = 'overdue' THEN 'overdue'
    ELSE 'open'
  END;

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  UPDATE group_contribution_obligations
  SET state = v_state,
    satisfied_at = CASE
      WHEN v_state IN ('satisfied', 'excess') THEN COALESCE(satisfied_at, p_occurred_at)
      ELSE satisfied_at END,
    updated_at = p_occurred_at
  WHERE id = p_obligation_id;

  -- Every applied allocation is recorded; the excess table stays reserved for
  -- money that genuinely exceeded the debt and now needs a disclosed decision.
  INSERT INTO group_contribution_settlements(
    organization_id, group_id, cycle_id, obligation_id, allocation_id, member_id,
    applied_minor, currency, settled_at
  ) VALUES (
    p_organization_id, p_group_id, v_obligation.cycle_id, p_obligation_id,
    p_allocation_id, v_obligation.member_id, v_allocation.amount_minor,
    v_allocation.currency, p_occurred_at
  );

  IF v_excess > 0 THEN
    INSERT INTO group_contribution_excess_payments(
      organization_id, group_id, cycle_id, obligation_id, allocation_id, member_id,
      excess_minor, disposition, created_at
    ) VALUES (
      p_organization_id, p_group_id, v_obligation.cycle_id, p_obligation_id,
      p_allocation_id, v_obligation.member_id, v_excess, 'unreconciled', p_occurred_at
    );
  END IF;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_obligation.product_id,
    'contribution_obligation', p_obligation_id, p_actor_id,
    'CONTRIBUTION_OBLIGATION_SETTLED',
    jsonb_build_object(
      'allocation_id', p_allocation_id, 'amount_minor', v_allocation.amount_minor,
      'owed_minor', v_owed, 'settled_before_minor', v_settled,
      'excess_minor', v_excess, 'obligation_state', v_state
    ), p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN p_obligation_id;
END;
$$;

-- Clause 4: an obligation may be adjusted only by an authorized, evidenced
-- command that preserves the original amount and reason. expected_minor is
-- never touched; the delta accumulates in adjusted_minor and the adjustment row
-- records what the original was at the time.
CREATE OR REPLACE FUNCTION adjust_group_contribution_obligation(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_obligation_id UUID,
  p_adjustment_kind TEXT,
  p_delta_minor BIGINT,
  p_reason_code TEXT,
  p_reason TEXT,
  p_evidence JSONB,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_obligation group_contribution_obligations;
  v_cycle group_contribution_cycles;
  v_adjustment_id UUID;
  v_new_adjusted BIGINT;
  v_state TEXT;
  v_owed BIGINT;
  v_settled BIGINT;
  v_previous TEXT;
BEGIN
  SELECT resource_id INTO v_adjustment_id FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_OBLIGATION_ADJUSTED';
  IF FOUND THEN RETURN v_adjustment_id; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_adjustment_kind NOT IN ('waiver', 'reduction', 'correction', 'write_off')
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    OR char_length(COALESCE(p_reason, '')) NOT BETWEEN 1 AND 1000
    OR p_delta_minor IS NULL OR p_delta_minor = 0
    OR jsonb_typeof(COALESCE(p_evidence, '{}'::JSONB)) <> 'object'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);

  SELECT * INTO v_obligation FROM group_contribution_obligations
  WHERE id = p_obligation_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_OBLIGATION_NOT_FOUND'; END IF;

  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = v_obligation.cycle_id FOR UPDATE;
  -- Clause 6: closed-cycle financial records are immutable.
  IF v_cycle.state IN ('closed', 'cancelled')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE'; END IF;

  v_new_adjusted := v_obligation.adjusted_minor + p_delta_minor;
  -- A waiver or write-off cancels the whole remaining debt and may not leave a
  -- negative obligation behind.
  IF v_obligation.expected_minor + v_new_adjusted < 0
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ADJUSTMENT_EXCEEDS_OBLIGATION'; END IF;

  SELECT COALESCE(sum(allocation.amount_minor), 0) INTO v_settled
  FROM group_contribution_settlements AS settlement
  JOIN group_contribution_allocations AS allocation
    ON allocation.id = settlement.allocation_id
  WHERE settlement.obligation_id = p_obligation_id AND allocation.state = 'allocated';

  v_owed := v_obligation.expected_minor + v_new_adjusted;
  v_state := CASE
    WHEN p_adjustment_kind = 'waiver' AND v_owed = 0 THEN 'waived'
    WHEN p_adjustment_kind = 'write_off' THEN 'written_off'
    WHEN v_settled > v_owed THEN 'excess'
    WHEN v_settled >= v_owed THEN 'satisfied'
    WHEN v_obligation.state = 'overdue' THEN 'overdue'
    ELSE 'open'
  END;

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  INSERT INTO group_contribution_obligation_adjustments(
    organization_id, cycle_id, obligation_id, adjustment_kind, reason_code, reason,
    delta_minor, original_expected_minor, applied_to_state, evidence, created_by,
    created_at
  ) VALUES (
    p_organization_id, v_obligation.cycle_id, p_obligation_id, p_adjustment_kind,
    p_reason_code, p_reason, p_delta_minor, v_obligation.expected_minor, v_state,
    COALESCE(p_evidence, '{}'::JSONB), p_actor_id, p_occurred_at
  ) RETURNING id INTO v_adjustment_id;

  UPDATE group_contribution_obligations
  SET adjusted_minor = v_new_adjusted, state = v_state,
    waived_at = CASE WHEN v_state = 'waived' THEN p_occurred_at ELSE waived_at END,
    written_off_at = CASE
      WHEN v_state = 'written_off' THEN p_occurred_at ELSE written_off_at END,
    updated_at = p_occurred_at
  WHERE id = p_obligation_id;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_obligation.product_id,
    'contribution_obligation_adjustment', v_adjustment_id, p_actor_id,
    'CONTRIBUTION_OBLIGATION_ADJUSTED',
    jsonb_build_object(
      'obligation_id', p_obligation_id, 'adjustment_kind', p_adjustment_kind,
      'delta_minor', p_delta_minor,
      'original_expected_minor', v_obligation.expected_minor,
      'reason_code', p_reason_code, 'obligation_state', v_state
    ), p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_adjustment_id;
END;
$$;

-- Cycle state transitions. open -> grace -> closing are servicing steps; the
-- legal transitions are fixed here rather than left to the caller.
CREATE OR REPLACE FUNCTION transition_group_contribution_cycle(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_cycle_id UUID,
  p_to_state TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cycle group_contribution_cycles;
  v_existing UUID;
  v_previous TEXT;
BEGIN
  SELECT resource_id INTO v_existing FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_CYCLE_TRANSITIONED';
  IF FOUND THEN RETURN p_to_state; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_to_state NOT IN ('grace', 'closing')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);

  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = p_cycle_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_NOT_FOUND'; END IF;

  IF NOT (
    (v_cycle.state = 'open' AND p_to_state = 'grace')
    OR (v_cycle.state IN ('open', 'grace') AND p_to_state = 'closing')
  ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_TRANSITION_INVALID'; END IF;

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  -- Entering grace or closing marks every still-unpaid obligation overdue, so
  -- the dashboard's overdue figure is a stored fact with a timestamp rather
  -- than a date comparison recomputed on every read.
  IF p_to_state IN ('grace', 'closing') THEN
    UPDATE group_contribution_obligations
    SET state = 'overdue', updated_at = p_occurred_at
    WHERE cycle_id = p_cycle_id AND state = 'open';
  END IF;

  UPDATE group_contribution_cycles
  SET state = p_to_state,
    grace_started_at = CASE
      WHEN p_to_state = 'grace' THEN p_occurred_at ELSE grace_started_at END,
    closing_started_at = CASE
      WHEN p_to_state = 'closing' THEN p_occurred_at ELSE closing_started_at END,
    updated_at = p_occurred_at
  WHERE id = p_cycle_id;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_cycle.product_id, 'contribution_cycle',
    p_cycle_id, p_actor_id, 'CONTRIBUTION_CYCLE_TRANSITIONED',
    jsonb_build_object('from_state', v_cycle.state, 'to_state', p_to_state),
    p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN p_to_state;
END;
$$;

-- Clause 6: closing requires a completion check, an exception report, and an
-- accounting period that can still accept the entry. The exception report is
-- computed here and stored on the cycle, so what the closer was shown is the
-- record of what was true at close.
CREATE OR REPLACE FUNCTION close_group_contribution_cycle(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_cycle_id UUID,
  p_close_reason_code TEXT,
  p_acknowledge_exceptions BOOLEAN,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cycle group_contribution_cycles;
  v_report JSONB;
  v_unreconciled INTEGER;
  v_unsettled INTEGER;
  v_period_state TEXT;
  v_period_id UUID;
  v_existing JSONB;
  v_previous TEXT;
BEGIN
  SELECT evidence INTO v_existing FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_CYCLE_CLOSED';
  IF FOUND THEN RETURN v_existing; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_close_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);

  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = p_cycle_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_NOT_FOUND'; END IF;
  IF v_cycle.state <> 'closing'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_NOT_CLOSING'; END IF;

  -- Clause 6: a closed cycle names the accounting period it landed in, so the
  -- period must exist and still be open. Closing into no period at all would
  -- leave the entry unattributable, and a locked or closed period must be
  -- reopened deliberately rather than silently written through.
  SELECT id, status INTO v_period_id, v_period_state FROM accounting_periods
  WHERE organization_id = p_organization_id
    AND v_cycle.period_end::DATE BETWEEN starts_on AND ends_on
  ORDER BY starts_on DESC LIMIT 1;
  IF v_period_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ACCOUNTING_PERIOD_MISSING'; END IF;
  IF v_period_state <> 'open'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_ACCOUNTING_PERIOD_CLOSED'; END IF;

  SELECT count(*) FILTER (WHERE disposition = 'unreconciled')
  INTO v_unreconciled FROM group_contribution_excess_payments
  WHERE cycle_id = p_cycle_id;

  SELECT count(*) INTO v_unsettled FROM group_contribution_obligations
  WHERE cycle_id = p_cycle_id AND state IN ('open', 'overdue', 'excess');

  SELECT jsonb_build_object(
    'obligations_total', count(*),
    'satisfied', count(*) FILTER (WHERE state = 'satisfied'),
    'open', count(*) FILTER (WHERE state = 'open'),
    'overdue', count(*) FILTER (WHERE state = 'overdue'),
    'waived', count(*) FILTER (WHERE state = 'waived'),
    'written_off', count(*) FILTER (WHERE state = 'written_off'),
    'excess', count(*) FILTER (WHERE state = 'excess'),
    'expected_minor', COALESCE(sum(expected_minor + adjusted_minor), 0),
    'unreconciled_excess_count', v_unreconciled
  ) INTO v_report FROM group_contribution_obligations
  WHERE cycle_id = p_cycle_id;

  -- Clause 5: unreconciled excess must be dispositioned before close, or it
  -- would be frozen into an immutable cycle with no disclosed destination.
  IF v_unreconciled > 0
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_EXCESS_UNRECONCILED'; END IF;
  -- Incomplete collection does not block a close, but it must be acknowledged
  -- explicitly rather than passed over in silence.
  IF v_unsettled > 0 AND COALESCE(p_acknowledge_exceptions, FALSE) IS NOT TRUE
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_EXCEPTIONS_UNACKNOWLEDGED'; END IF;

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  UPDATE group_contribution_cycles
  SET state = 'closed', closed_at = p_occurred_at, closed_by = p_actor_id,
    close_reason_code = p_close_reason_code, accounting_period_id = v_period_id,
    exception_report = v_report, updated_at = p_occurred_at
  WHERE id = p_cycle_id;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_cycle.product_id, 'contribution_cycle',
    p_cycle_id, p_actor_id, 'CONTRIBUTION_CYCLE_CLOSED',
    v_report || jsonb_build_object('acknowledged_exceptions', v_unsettled > 0),
    p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN v_report;
END;
$$;

-- A cycle is cancellable only while nothing has been collected against it.
-- Once money has moved, the cycle must be closed with an exception report
-- instead, so the collection stays visible.
CREATE OR REPLACE FUNCTION cancel_group_contribution_cycle(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_cycle_id UUID,
  p_reason_code TEXT,
  p_reason TEXT,
  p_correlation_id UUID,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cycle group_contribution_cycles;
  v_existing UUID;
  v_previous TEXT;
BEGIN
  SELECT resource_id INTO v_existing FROM group_contribution_events
  WHERE organization_id = p_organization_id AND correlation_id = p_correlation_id
    AND event_type = 'CONTRIBUTION_CYCLE_CANCELLED';
  IF FOUND THEN RETURN v_existing; END IF;
  IF p_correlation_id IS NULL OR p_occurred_at IS NULL
    OR p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$'
    OR char_length(COALESCE(p_reason, '')) NOT BETWEEN 1 AND 1000
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_COMMAND_INVALID'; END IF;

  PERFORM assert_group_governance_actor(p_organization_id, p_group_id, p_actor_id);

  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = p_cycle_id AND organization_id = p_organization_id
    AND group_id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_NOT_FOUND'; END IF;
  IF v_cycle.state IN ('closed', 'cancelled')
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE'; END IF;

  IF EXISTS (
    SELECT 1 FROM group_contribution_settlements WHERE cycle_id = p_cycle_id
  ) THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_HAS_COLLECTIONS'; END IF;

  v_previous := current_setting('microfams.group_contribution_engine', TRUE);
  PERFORM set_config('microfams.group_contribution_engine', 'on', TRUE);

  UPDATE group_contribution_cycles
  SET state = 'cancelled', cancelled_at = p_occurred_at,
    cancellation_reason_code = p_reason_code, cancellation_reason = p_reason,
    updated_at = p_occurred_at
  WHERE id = p_cycle_id;

  INSERT INTO group_contribution_events(
    organization_id, group_id, product_id, resource_type, resource_id, actor_id,
    event_type, evidence, correlation_id, occurred_at
  ) VALUES (
    p_organization_id, p_group_id, v_cycle.product_id, 'contribution_cycle',
    p_cycle_id, p_actor_id, 'CONTRIBUTION_CYCLE_CANCELLED',
    jsonb_build_object(
      'from_state', v_cycle.state, 'reason_code', p_reason_code, 'reason', p_reason
    ), p_correlation_id, p_occurred_at
  );

  PERFORM set_config('microfams.group_contribution_engine', COALESCE(v_previous, ''), TRUE);
  RETURN p_cycle_id;
END;
$$;

-- Clause 6: once a cycle is closed its financial records are immutable. The
-- engine flag is not an escape hatch here — nothing may rewrite a closed
-- cycle's obligations, settlements, or adjustments, including the engine.
CREATE OR REPLACE FUNCTION protect_closed_group_contribution_cycle()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cycle_id UUID;
  v_state TEXT;
BEGIN
  v_cycle_id := COALESCE(OLD.cycle_id, NEW.cycle_id);
  SELECT state INTO v_state FROM group_contribution_cycles WHERE id = v_cycle_id;
  IF v_state = 'closed' THEN
    RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_closed_cycle_obligations
  ON group_contribution_obligations;
CREATE TRIGGER trg_protect_closed_cycle_obligations
  BEFORE UPDATE OR DELETE ON group_contribution_obligations
  FOR EACH ROW EXECUTE FUNCTION protect_closed_group_contribution_cycle();

DROP TRIGGER IF EXISTS trg_protect_closed_cycle_settlements
  ON group_contribution_settlements;
CREATE TRIGGER trg_protect_closed_cycle_settlements
  BEFORE UPDATE OR DELETE ON group_contribution_settlements
  FOR EACH ROW EXECUTE FUNCTION protect_closed_group_contribution_cycle();

DROP TRIGGER IF EXISTS trg_protect_closed_cycle_adjustments
  ON group_contribution_obligation_adjustments;
CREATE TRIGGER trg_protect_closed_cycle_adjustments
  BEFORE UPDATE OR DELETE ON group_contribution_obligation_adjustments
  FOR EACH ROW EXECUTE FUNCTION protect_closed_group_contribution_cycle();

-- The cycle row itself: once closed, only the engine's own close write is
-- allowed to have set it there, and nothing may move it afterwards.
CREATE OR REPLACE FUNCTION protect_group_contribution_cycle_row()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE';
  END IF;
  IF OLD.state = 'closed'
    AND current_setting('microfams.group_contribution_engine', TRUE) IS DISTINCT FROM 'on'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE'; END IF;
  IF OLD.state = 'closed' AND NEW.state <> 'closed'
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_IMMUTABLE'; END IF;
  -- The opening snapshot and the rule version it was billed under can never be
  -- rewritten, in any state (clause 1). The snapshot is written once, just after
  -- the obligations it describes are generated, so the transition from the empty
  -- default is the single legitimate write; every later change is refused.
  IF NEW.rule_version_id <> OLD.rule_version_id
    OR NEW.period_key <> OLD.period_key
    OR NEW.currency <> OLD.currency
    OR (OLD.eligibility_snapshot <> '{}'::JSONB
      AND NEW.eligibility_snapshot <> OLD.eligibility_snapshot)
  THEN RAISE EXCEPTION 'GROUP_CONTRIBUTION_CYCLE_SNAPSHOT_IMMUTABLE'; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_group_contribution_cycle_row
  ON group_contribution_cycles;
CREATE TRIGGER trg_protect_group_contribution_cycle_row
  BEFORE UPDATE OR DELETE ON group_contribution_cycles
  FOR EACH ROW EXECUTE FUNCTION protect_group_contribution_cycle_row();

-- Clause 7: the dashboard must distinguish expected, received, pending,
-- overdue, waived, refunded, and unreconciled, and money must derive from
-- posted journals. Received therefore sums the journal-linked allocations
-- behind each settlement rather than any counter, so a reversed allocation
-- lowers the received figure with no extra bookkeeping.
CREATE OR REPLACE FUNCTION read_group_contribution_cycle_dashboard(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_cycle_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cycle group_contribution_cycles;
  v_result JSONB;
BEGIN
  SELECT * INTO v_cycle FROM group_contribution_cycles
  WHERE id = p_cycle_id AND organization_id = p_organization_id
    AND group_id = p_group_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  -- A member of the group, or a tenant governance/audit role, may read.
  IF NOT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = p_group_id AND organization_id = p_organization_id
      AND user_id = p_actor_id AND status = 'active'
  ) AND NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id AND user_id = p_actor_id
      AND status = 'active'
      AND (role = 'owner' OR permissions && ARRAY[
        'groups.governance.manage', 'groups.contributions.manage', 'groups.audit.read'
      ]::TEXT[])
  ) THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'cycle', jsonb_build_object(
      'id', v_cycle.id, 'state', v_cycle.state, 'period_key', v_cycle.period_key,
      'currency', v_cycle.currency, 'due_date', v_cycle.due_date,
      'grace_end_date', v_cycle.grace_end_date,
      'rule_version_id', v_cycle.rule_version_id,
      'expected_total_minor', v_cycle.expected_total_minor,
      'obligation_count', v_cycle.obligation_count,
      'exception_report', v_cycle.exception_report
    ),
    'expected_minor', COALESCE((
      SELECT sum(expected_minor + adjusted_minor)
      FROM group_contribution_obligations
      WHERE cycle_id = p_cycle_id AND state NOT IN ('waived', 'written_off')
    ), 0),
    'received_minor', COALESCE((
      SELECT sum(allocation.amount_minor)
      FROM group_contribution_settlements AS settlement
      JOIN group_contribution_allocations AS allocation
        ON allocation.id = settlement.allocation_id
      WHERE settlement.cycle_id = p_cycle_id AND allocation.state = 'allocated'
    ), 0),
    'waived_minor', COALESCE((
      SELECT sum(expected_minor + adjusted_minor)
      FROM group_contribution_obligations
      WHERE cycle_id = p_cycle_id AND state = 'waived'
    ), 0),
    'written_off_minor', COALESCE((
      SELECT sum(expected_minor + adjusted_minor)
      FROM group_contribution_obligations
      WHERE cycle_id = p_cycle_id AND state = 'written_off'
    ), 0),
    'overdue_minor', COALESCE((
      SELECT sum(expected_minor + adjusted_minor)
      FROM group_contribution_obligations
      WHERE cycle_id = p_cycle_id AND state = 'overdue'
    ), 0),
    -- Reversed allocations are money that was received and then taken back.
    'reversed_minor', COALESCE((
      SELECT sum(allocation.amount_minor)
      FROM group_contribution_settlements AS settlement
      JOIN group_contribution_allocations AS allocation
        ON allocation.id = settlement.allocation_id
      WHERE settlement.cycle_id = p_cycle_id AND allocation.state = 'reversed'
    ), 0),
    'unreconciled_excess_minor', COALESCE((
      SELECT sum(excess_minor) FROM group_contribution_excess_payments
      WHERE cycle_id = p_cycle_id AND disposition = 'unreconciled'
    ), 0),
    'refunded_excess_minor', COALESCE((
      SELECT sum(excess_minor) FROM group_contribution_excess_payments
      WHERE cycle_id = p_cycle_id AND disposition = 'refunded'
    ), 0),
    'obligation_states', COALESCE((
      SELECT jsonb_object_agg(state, count)
      FROM (
        SELECT state, count(*) AS count FROM group_contribution_obligations
        WHERE cycle_id = p_cycle_id GROUP BY state
      ) AS grouped
    ), '{}'::JSONB)
  ) INTO v_result;

  -- Pending is what is still expected but not yet received; it is derived, not
  -- stored, so it cannot drift from the two figures it sits between.
  RETURN v_result || jsonb_build_object(
    'pending_minor', GREATEST(
      (v_result->>'expected_minor')::BIGINT - (v_result->>'received_minor')::BIGINT, 0
    )
  );
END;
$$;

ALTER TABLE group_contribution_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_contribution_obligations ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_contribution_obligation_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_contribution_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_contribution_excess_payments ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'group_contribution_cycles', 'group_contribution_obligations',
    'group_contribution_settlements', 'group_contribution_excess_payments'
  ] LOOP
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

-- The adjustments table has no group_id of its own; it is tenant-scoped through
-- organization_id like the rest.
DROP POLICY IF EXISTS tenant_read ON group_contribution_obligation_adjustments;
CREATE POLICY tenant_read ON group_contribution_obligation_adjustments FOR SELECT
  USING (has_active_organization_membership(organization_id));
REVOKE ALL ON group_contribution_obligation_adjustments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON group_contribution_obligation_adjustments TO service_role;
REVOKE INSERT, UPDATE, DELETE ON group_contribution_obligation_adjustments FROM service_role;

REVOKE ALL ON FUNCTION open_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, DATE, DATE, DATE, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION settle_group_contribution_obligation(
  UUID, UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION adjust_group_contribution_obligation(
  UUID, UUID, UUID, UUID, TEXT, BIGINT, TEXT, TEXT, JSONB, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION transition_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION close_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, BOOLEAN, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cancel_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION read_group_contribution_cycle_dashboard(
  UUID, UUID, UUID, UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION open_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, DATE, DATE, DATE, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION settle_group_contribution_obligation(
  UUID, UUID, UUID, UUID, UUID, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION adjust_group_contribution_obligation(
  UUID, UUID, UUID, UUID, TEXT, BIGINT, TEXT, TEXT, JSONB, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION transition_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION close_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, BOOLEAN, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION cancel_group_contribution_cycle(
  UUID, UUID, UUID, UUID, TEXT, TEXT, UUID, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION read_group_contribution_cycle_dashboard(
  UUID, UUID, UUID, UUID
) TO service_role;
