-- GT-06A: group treasury budgets, reservations, and internal disbursements.
--
-- This slice covers the part of GT-06 where money moves under governance but
-- stays inside the ledger. External provider payouts, timeout recovery, and
-- emergency expenditure are GT-06B; the reservation primitive installed here is
-- what that slice will consume.
--
-- Spec clause 2 is the load-bearing one: approval reserves funds atomically and
-- voting alone must never debit a mutable balance. The legacy
-- groups.group_fund_balance column is exactly the mutable balance the clause
-- forbids, so nothing here touches it. Available funds are derived from posted
-- journal lines minus active reservations, which means a reservation cannot be
-- double-spent even under concurrent approval.
--
-- Clause 3 requires a final checker holding the treasury approve permission, at
-- least two distinct approving actors, and separation between proposer, checker,
-- and beneficiary. The seeded office set grants the treasurer
-- groups.treasury.make but no office held an approve permission, so no
-- disbursement could have passed its own final check. This migration adds
-- groups.treasury.approve to the chair office: the treasurer prepares and the
-- chair countersigns, which makes the separation structural rather than a rule
-- the caller is trusted to respect.

-- A budget is the authorised spending envelope clause 1 requires a command to
-- identify. Committed and disbursed totals are maintained by the engine from
-- reservation and disbursement transitions, never written by a caller.
CREATE TABLE IF NOT EXISTS group_treasury_budgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  budget_key TEXT NOT NULL CHECK (budget_key ~ '^[a-z][a-z0-9_-]{1,47}$'),
  display_name TEXT NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 2 AND 120),
  purpose TEXT NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 8 AND 2000),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  ceiling_minor BIGINT NOT NULL
    CHECK (ceiling_minor > 0 AND ceiling_minor <= 100000000000),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft'
    CHECK (state IN ('draft', 'active', 'exhausted', 'closed', 'cancelled')),
  -- Clause 4: a constitution may disclose a lower-threshold band for low-value
  -- spend. Null means no band, so the full clause 3 threshold always applies.
  low_value_band_minor BIGINT
    CHECK (low_value_band_minor IS NULL OR low_value_band_minor > 0),
  low_value_quorum_bps INTEGER
    CHECK (low_value_quorum_bps IS NULL OR low_value_quorum_bps BETWEEN 1 AND 10000),
  low_value_approval_bps INTEGER
    CHECK (low_value_approval_bps IS NULL OR low_value_approval_bps BETWEEN 1 AND 10000),
  committed_minor BIGINT NOT NULL DEFAULT 0 CHECK (committed_minor >= 0),
  disbursed_minor BIGINT NOT NULL DEFAULT 0 CHECK (disbursed_minor >= 0),
  budget_proposal_id UUID REFERENCES group_proposals(id) ON DELETE RESTRICT,
  opened_by UUID REFERENCES users(id) ON DELETE SET NULL,
  opened_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (group_id, budget_key, period_start),
  CHECK (period_end > period_start),
  CHECK (disbursed_minor <= ceiling_minor),
  CHECK (committed_minor + disbursed_minor <= ceiling_minor),
  -- A band is disclosed as a whole or not at all; a ceiling with no thresholds
  -- would silently fall back to the default and read as a weaker rule than it is.
  CHECK (
    (low_value_band_minor IS NULL
      AND low_value_quorum_bps IS NULL AND low_value_approval_bps IS NULL)
    OR (low_value_band_minor IS NOT NULL
      AND low_value_quorum_bps IS NOT NULL AND low_value_approval_bps IS NOT NULL)
  ),
  CHECK (low_value_band_minor IS NULL OR low_value_band_minor < ceiling_minor),
  CHECK ((state = 'active') = (opened_at IS NOT NULL) OR state IN ('exhausted', 'closed')),
  CHECK ((state IN ('closed', 'cancelled')) = (closed_at IS NOT NULL))
);

-- One row per governed spend request. The amount, beneficiary, and window are
-- fixed at request time; clause 5 snapshots the balance and rule at approval so
-- the decision stays explainable, and execution revalidates against live state.
CREATE TABLE IF NOT EXISTS group_treasury_disbursements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  budget_id UUID NOT NULL REFERENCES group_treasury_budgets(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  proposal_id UUID NOT NULL REFERENCES group_proposals(id) ON DELETE RESTRICT,
  -- Clause 6: this slice settles internal beneficiaries only. The column is
  -- present so GT-06B can add 'external' without restating the table.
  channel TEXT NOT NULL DEFAULT 'internal' CHECK (channel IN ('internal')),
  beneficiary_kind TEXT NOT NULL
    CHECK (beneficiary_kind IN ('member', 'group', 'project')),
  beneficiary_member_id UUID REFERENCES group_members(id) ON DELETE RESTRICT,
  beneficiary_user_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  beneficiary_group_id UUID REFERENCES groups(id) ON DELETE RESTRICT,
  beneficiary_project_id UUID,
  amount_minor BIGINT NOT NULL
    CHECK (amount_minor > 0 AND amount_minor <= 100000000000),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  purpose TEXT NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 8 AND 2000),
  evidence_uri TEXT NOT NULL CHECK (char_length(btrim(evidence_uri)) BETWEEN 3 AND 500),
  execute_from TIMESTAMPTZ NOT NULL,
  execute_until TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'requested' CHECK (state IN (
    'requested', 'approved', 'executed', 'rejected', 'cancelled', 'expired', 'reversed'
  )),
  requested_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  -- Clause 3: the checker is recorded separately from the proposer and is
  -- constrained below to be a different person holding the approve permission.
  final_checker_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  approver_count INTEGER NOT NULL DEFAULT 0 CHECK (approver_count >= 0),
  -- Clause 5: what was true when the decision was made.
  available_minor_at_approval BIGINT
    CHECK (available_minor_at_approval IS NULL OR available_minor_at_approval >= 0),
  quorum_bps_applied INTEGER
    CHECK (quorum_bps_applied IS NULL OR quorum_bps_applied BETWEEN 1 AND 10000),
  approval_bps_applied INTEGER
    CHECK (approval_bps_applied IS NULL OR approval_bps_applied BETWEEN 1 AND 10000),
  threshold_basis TEXT
    CHECK (threshold_basis IS NULL OR threshold_basis IN ('default', 'low_value_band')),
  reservation_id UUID,
  execution_journal_entry_id UUID REFERENCES journal_entries(id) ON DELETE RESTRICT,
  reversal_journal_entry_id UUID REFERENCES journal_entries(id) ON DELETE RESTRICT,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  correlation_id UUID NOT NULL,
  approved_at TIMESTAMPTZ,
  executed_at TIMESTAMPTZ,
  settled_state_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (proposal_id),
  UNIQUE (execution_journal_entry_id),
  UNIQUE (reversal_journal_entry_id),
  CHECK (execute_until > execute_from),
  -- The beneficiary identity must match the kind it claims, so a member payout
  -- cannot quietly carry a group destination.
  CHECK (
    (beneficiary_kind = 'member' AND beneficiary_member_id IS NOT NULL
      AND beneficiary_user_id IS NOT NULL AND beneficiary_group_id IS NULL
      AND beneficiary_project_id IS NULL)
    OR (beneficiary_kind = 'group' AND beneficiary_group_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_project_id IS NULL)
    OR (beneficiary_kind = 'project' AND beneficiary_project_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_group_id IS NULL)
  ),
  -- Clause 3: no self-approval, and the checker is never the beneficiary.
  CHECK (final_checker_id IS NULL OR final_checker_id <> requested_by),
  CHECK (final_checker_id IS NULL OR beneficiary_user_id IS NULL
    OR final_checker_id <> beneficiary_user_id),
  -- Approval is only meaningful with its full snapshot attached.
  CHECK (
    (state = 'requested' AND approved_at IS NULL AND final_checker_id IS NULL)
    OR (state <> 'requested')
  ),
  -- A disbursement that reached approval keeps its approval evidence even after
  -- it is later cancelled or expires, so the record still shows who signed it
  -- off. Only states that never passed approval must have no approval stamp.
  CHECK (approved_at IS NULL OR state NOT IN ('requested', 'rejected')),
  CHECK (state NOT IN ('approved', 'executed', 'reversed') OR approved_at IS NOT NULL),
  CHECK (approved_at IS NULL OR (
    final_checker_id IS NOT NULL AND available_minor_at_approval IS NOT NULL
    AND quorum_bps_applied IS NOT NULL AND approval_bps_applied IS NOT NULL
    AND threshold_basis IS NOT NULL AND approver_count >= 2
  )),
  -- The execution journal is retained through reversal: reversing posts a second,
  -- opposing entry rather than erasing the first.
  CHECK ((execution_journal_entry_id IS NOT NULL) = (state IN ('executed', 'reversed'))),
  CHECK ((executed_at IS NOT NULL) = (state IN ('executed', 'reversed'))),
  CHECK ((state = 'reversed') = (reversal_journal_entry_id IS NOT NULL))
);
-- Clause 2: the reservation is the commitment. It exists from approval until the
-- disbursement executes, releases, or expires, and available funds subtract it,
-- so two concurrent approvals cannot both spend the same money.
CREATE TABLE IF NOT EXISTS group_treasury_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  budget_id UUID NOT NULL REFERENCES group_treasury_budgets(id) ON DELETE RESTRICT,
  disbursement_id UUID NOT NULL
    REFERENCES group_treasury_disbursements(id) ON DELETE RESTRICT,
  source_account_id UUID NOT NULL REFERENCES financial_accounts(id) ON DELETE RESTRICT,
  amount_minor BIGINT NOT NULL
    CHECK (amount_minor > 0 AND amount_minor <= 100000000000),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'active'
    CHECK (state IN ('active', 'consumed', 'released', 'expired')),
  -- Clause 5: the balance this reservation was taken against, for later audit.
  available_minor_at_reserve BIGINT NOT NULL CHECK (available_minor_at_reserve >= 0),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_journal_entry_id UUID REFERENCES journal_entries(id) ON DELETE RESTRICT,
  reserved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  release_reason_code TEXT
    CHECK (release_reason_code IS NULL OR release_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  correlation_id UUID NOT NULL,
  consumed_at TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  expired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Clause 7: at most one active reservation per disbursement, so a release or a
  -- consume can happen exactly once rather than racing a duplicate.
  UNIQUE (disbursement_id),
  UNIQUE (consumed_journal_entry_id),
  CHECK ((state = 'consumed') = (consumed_journal_entry_id IS NOT NULL)),
  CHECK ((state = 'consumed') = (consumed_at IS NOT NULL)),
  CHECK ((state = 'released') = (released_at IS NOT NULL)),
  CHECK ((state = 'expired') = (expired_at IS NOT NULL)),
  CHECK (state <> 'released' OR release_reason_code IS NOT NULL)
);

-- Append-only evidence for every treasury transition.
CREATE TABLE IF NOT EXISTS group_treasury_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  budget_id UUID REFERENCES group_treasury_budgets(id) ON DELETE RESTRICT,
  disbursement_id UUID REFERENCES group_treasury_disbursements(id) ON DELETE RESTRICT,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_.]{2,63}$'),
  from_state TEXT,
  to_state TEXT,
  amount_minor BIGINT CHECK (amount_minor IS NULL OR amount_minor > 0),
  reason_code TEXT CHECK (reason_code IS NULL OR reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  detail JSONB NOT NULL DEFAULT '{}'::JSONB,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  correlation_id UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_treasury_budgets_group_state
  ON group_treasury_budgets(organization_id, group_id, state);
CREATE INDEX IF NOT EXISTS idx_group_treasury_disbursements_group_state
  ON group_treasury_disbursements(organization_id, group_id, state);
CREATE INDEX IF NOT EXISTS idx_group_treasury_disbursements_budget
  ON group_treasury_disbursements(budget_id, state);
CREATE INDEX IF NOT EXISTS idx_group_treasury_reservations_active
  ON group_treasury_reservations(organization_id, group_id, state)
  WHERE state = 'active';
CREATE INDEX IF NOT EXISTS idx_group_treasury_events_disbursement
  ON group_treasury_events(disbursement_id, occurred_at DESC);
-- Engine lock. Treasury rows are evidence: they may only be written by the
-- functions below, which enforce the governance and separation rules. A direct
-- insert or update from a caller is refused even with table privileges.
CREATE OR REPLACE FUNCTION protect_group_treasury_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_treasury_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  -- A budget is still editable while it is a draft; once active it is governed.
  IF TG_TABLE_NAME = 'group_treasury_budgets'
    AND TG_OP = 'UPDATE' AND OLD.state = 'draft' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'GROUP_TREASURY_ENGINE_REQUIRED';
END;
$$;

DROP TRIGGER IF EXISTS protect_group_treasury_budgets ON group_treasury_budgets;
CREATE TRIGGER protect_group_treasury_budgets
  BEFORE UPDATE OR DELETE ON group_treasury_budgets
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();
DROP TRIGGER IF EXISTS protect_group_treasury_disbursements ON group_treasury_disbursements;
CREATE TRIGGER protect_group_treasury_disbursements
  BEFORE INSERT OR UPDATE OR DELETE ON group_treasury_disbursements
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();
DROP TRIGGER IF EXISTS protect_group_treasury_reservations ON group_treasury_reservations;
CREATE TRIGGER protect_group_treasury_reservations
  BEFORE INSERT OR UPDATE OR DELETE ON group_treasury_reservations
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();
DROP TRIGGER IF EXISTS protect_group_treasury_events ON group_treasury_events;
CREATE TRIGGER protect_group_treasury_events
  BEFORE INSERT OR UPDATE OR DELETE ON group_treasury_events
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();

-- The group's spendable treasury account. Contribution income lands here under
-- GT-04; member-attributed capital and project-restricted funds deliberately do
-- not, because neither is a general spendable balance.
CREATE OR REPLACE FUNCTION group_treasury_account_id(
  p_organization_id UUID, p_group_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_group_key TEXT;
BEGIN
  v_group_key := upper(substr(md5(p_group_id::TEXT), 1, 16));
  RETURN ensure_wallet_system_account(
    p_organization_id, 'GROUP.' || v_group_key || '.TREASURY',
    'Group treasury spendable funds', 'liability', 'credit'
  );
END;
$$;

-- Clause 2 and clause 5: available funds derive from posted journals minus
-- active reservations. Nothing here reads groups.group_fund_balance, which is
-- the mutable balance the clause forbids spending against.
CREATE OR REPLACE FUNCTION group_treasury_available_minor(
  p_organization_id UUID, p_group_id UUID
) RETURNS BIGINT
-- Deliberately not STABLE: resolving the treasury account provisions it on
-- first use, so this function may write.
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
  v_posted BIGINT;
  v_reserved BIGINT;
BEGIN
  v_account_id := group_treasury_account_id(p_organization_id, p_group_id);
  v_posted := COALESCE(wallet_account_balance_minor(v_account_id), 0);
  SELECT COALESCE(SUM(amount_minor), 0) INTO v_reserved
  FROM group_treasury_reservations
  WHERE organization_id = p_organization_id
    AND group_id = p_group_id
    AND state = 'active';
  RETURN GREATEST(v_posted - v_reserved, 0);
END;
$$;
-- Clause 3 requires a final checker holding groups.treasury.approve. The seeded
-- office set granted the treasurer groups.treasury.make but gave no office an
-- approve permission, so before this migration no disbursement could pass its
-- own final check. The chair gets approve: the treasurer prepares and the chair
-- countersigns, which makes maker/checker separation structural.
--
-- Existing constitutions are backfilled through the governance engine flag so
-- the protection trigger stays honoured. Only the chair office is touched, and
-- only to add a permission it does not already hold.
DO $$
DECLARE v_previous TEXT;
BEGIN
  v_previous := current_setting('microfams.group_governance_engine', TRUE);
  PERFORM set_config('microfams.group_governance_engine', 'on', TRUE);

  UPDATE group_office_definitions
  SET permissions = array_append(permissions, 'groups.treasury.approve')
  WHERE office_key = 'chair'
    AND NOT (permissions @> ARRAY['groups.treasury.approve']::TEXT[]);

  PERFORM set_config(
    'microfams.group_governance_engine', COALESCE(v_previous, ''), TRUE
  );
END $$;

-- The backfill above only reaches constitutions that already exist. New ones are
-- seeded by two separate paths in install_group_constitution_offices.sql (a bulk
-- INSERT and the adopt function), so rather than duplicating a large function
-- here and risking the two drifting apart, the invariant is enforced where it
-- cannot be bypassed: any chair office definition gains the approve permission
-- as it is written.
CREATE OR REPLACE FUNCTION ensure_group_chair_treasury_approval() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.office_key = 'chair'
    AND NOT (NEW.permissions @> ARRAY['groups.treasury.approve']::TEXT[]) THEN
    NEW.permissions := array_append(NEW.permissions, 'groups.treasury.approve');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ensure_group_chair_treasury_approval
  ON group_office_definitions;
CREATE TRIGGER ensure_group_chair_treasury_approval
  BEFORE INSERT OR UPDATE ON group_office_definitions
  FOR EACH ROW EXECUTE FUNCTION ensure_group_chair_treasury_approval();

-- Tenant roles that already carry governance authority gain the matching
-- treasury approve permission, so an owner or governance manager can act as
-- checker without a separate grant step.
UPDATE organization_memberships
SET permissions = array_append(permissions, 'groups.treasury.approve')
WHERE (role = 'owner' OR permissions @> ARRAY['groups.governance.manage']::TEXT[])
  AND NOT (permissions @> ARRAY['groups.treasury.approve']::TEXT[]);

-- Resolves whether a user may act as final checker for this group. Authority
-- comes from an active office in the current constitution, or from a tenant
-- role. Held separately from the group-membership check because a checker must
-- be a real person with the permission, not merely a member.
CREATE OR REPLACE FUNCTION group_treasury_checker_permitted(
  p_organization_id UUID, p_group_id UUID, p_user_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NULL THEN RETURN FALSE; END IF;
  RETURN EXISTS (
    SELECT 1
    FROM group_office_assignments AS assignment
    JOIN group_office_definitions AS definition
      ON definition.constitution_id = assignment.constitution_id
      AND definition.office_key = assignment.office_key
    JOIN groups AS group_record ON group_record.id = assignment.group_id
    WHERE assignment.organization_id = p_organization_id
      AND assignment.group_id = p_group_id
      AND assignment.user_id = p_user_id
      AND assignment.state IN ('active', 'delegated')
      AND assignment.constitution_id = group_record.current_constitution_id
      AND definition.permissions @> ARRAY['groups.treasury.approve']::TEXT[]
  ) OR EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = p_organization_id
      AND user_id = p_user_id
      AND status = 'active'
      AND (role = 'owner'
        OR permissions @> ARRAY['groups.treasury.approve']::TEXT[])
  );
END;
$$;
-- Activates a budget. Clause 1 wants a command to name an authorised envelope,
-- so a budget must be active before it can carry a disbursement.
CREATE OR REPLACE FUNCTION activate_group_treasury_budget(
  p_organization_id UUID,
  p_budget_id UUID,
  p_actor_id UUID,
  p_correlation_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_budget group_treasury_budgets;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_budget FROM group_treasury_budgets
  WHERE id = p_budget_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_FOUND'; END IF;
  IF v_budget.state <> 'draft' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_DRAFT';
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE group_treasury_budgets
  SET state = 'active', opened_by = p_actor_id, opened_at = NOW(), updated_at = NOW()
  WHERE id = p_budget_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, event_type, from_state, to_state,
    actor_id, correlation_id
  ) VALUES (
    p_organization_id, v_budget.group_id, p_budget_id, 'budget.activated',
    'draft', 'active', p_actor_id, p_correlation_id
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN p_budget_id;
END;
$$;

-- Clause 1: records a spend request against an active budget. This only creates
-- the request; no funds move and nothing is reserved until approval.
-- Idempotent on (organization_id, idempotency_key).
CREATE OR REPLACE FUNCTION request_group_treasury_disbursement(
  p_organization_id UUID,
  p_group_id UUID,
  p_budget_id UUID,
  p_proposal_id UUID,
  p_beneficiary_kind TEXT,
  p_beneficiary_member_id UUID,
  p_beneficiary_group_id UUID,
  p_beneficiary_project_id UUID,
  p_amount_minor BIGINT,
  p_currency VARCHAR(3),
  p_purpose TEXT,
  p_evidence_uri TEXT,
  p_execute_from TIMESTAMPTZ,
  p_execute_until TIMESTAMPTZ,
  p_requested_by UUID,
  p_idempotency_key TEXT,
  p_correlation_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_budget group_treasury_budgets;
  v_existing UUID;
  v_beneficiary_user_id UUID;
  v_disbursement_id UUID;
  v_previous TEXT;
BEGIN
  SELECT id INTO v_existing FROM group_treasury_disbursements
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  SELECT * INTO v_budget FROM group_treasury_budgets
  WHERE id = p_budget_id AND organization_id = p_organization_id AND group_id = p_group_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_FOUND'; END IF;
  IF v_budget.state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_ACTIVE';
  END IF;
  IF v_budget.currency <> p_currency THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CURRENCY_MISMATCH';
  END IF;
  -- The envelope is a hard ceiling: an uncommitted request that could not fit is
  -- refused at request time rather than surviving to fail at execution.
  IF v_budget.committed_minor + v_budget.disbursed_minor + p_amount_minor
    > v_budget.ceiling_minor THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_CEILING_EXCEEDED';
  END IF;

  IF p_beneficiary_kind = 'member' THEN
    SELECT user_id INTO v_beneficiary_user_id FROM group_members
    WHERE id = p_beneficiary_member_id AND group_id = p_group_id;
    IF v_beneficiary_user_id IS NULL THEN
      RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_MEMBER';
    END IF;
    -- Clause 3: separation between proposer and beneficiary. Refused here so a
    -- self-directed request never reaches a voting round.
    IF v_beneficiary_user_id = p_requested_by THEN
      RAISE EXCEPTION 'GROUP_TREASURY_SELF_BENEFICIARY_FORBIDDEN';
    END IF;
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO group_treasury_disbursements(
    organization_id, group_id, budget_id, constitution_id, proposal_id,
    beneficiary_kind, beneficiary_member_id, beneficiary_user_id,
    beneficiary_group_id, beneficiary_project_id, amount_minor, currency,
    purpose, evidence_uri, execute_from, execute_until, state, requested_by,
    idempotency_key, correlation_id
  ) VALUES (
    p_organization_id, p_group_id, p_budget_id, v_budget.constitution_id,
    p_proposal_id, p_beneficiary_kind, p_beneficiary_member_id,
    v_beneficiary_user_id, p_beneficiary_group_id, p_beneficiary_project_id,
    p_amount_minor, p_currency, p_purpose, p_evidence_uri, p_execute_from,
    p_execute_until, 'requested', p_requested_by, p_idempotency_key,
    p_correlation_id
  ) RETURNING id INTO v_disbursement_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    to_state, amount_minor, actor_id, correlation_id
  ) VALUES (
    p_organization_id, p_group_id, p_budget_id, v_disbursement_id,
    'disbursement.requested', 'requested', p_amount_minor, p_requested_by,
    p_correlation_id
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_disbursement_id;
END;
$$;
-- Clauses 2, 3, 4, and 5. Approval is the moment funds become committed, so this
-- function does all four things in one transaction: verify the governance
-- outcome, verify separation of duties, snapshot what was true, and reserve the
-- money. If any check fails nothing is committed and no reservation exists.
CREATE OR REPLACE FUNCTION approve_group_treasury_disbursement(
  p_organization_id UUID,
  p_disbursement_id UUID,
  p_final_checker_id UUID,
  p_correlation_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_disbursement group_treasury_disbursements;
  v_budget group_treasury_budgets;
  v_proposal group_proposals;
  v_snapshot group_voting_snapshots;
  v_approver_count INTEGER;
  v_available BIGINT;
  v_account_id UUID;
  v_threshold_basis TEXT;
  v_quorum_bps INTEGER;
  v_approval_bps INTEGER;
  v_reservation_id UUID;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = p_disbursement_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  IF v_disbursement.state <> 'requested' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_PENDING';
  END IF;

  -- Clause 3: the checker must be someone other than the proposer, must not be
  -- the beneficiary, and must actually hold the approve permission.
  IF p_final_checker_id = v_disbursement.requested_by THEN
    RAISE EXCEPTION 'GROUP_TREASURY_SELF_APPROVAL_FORBIDDEN';
  END IF;
  IF v_disbursement.beneficiary_user_id IS NOT NULL
    AND p_final_checker_id = v_disbursement.beneficiary_user_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHECKER_IS_BENEFICIARY';
  END IF;
  IF NOT group_treasury_checker_permitted(
    p_organization_id, v_disbursement.group_id, p_final_checker_id
  ) THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHECKER_NOT_PERMITTED';
  END IF;

  -- The governance outcome is the proposal engine's, not ours. We require it to
  -- have actually passed rather than re-deriving the tally.
  SELECT * INTO v_proposal FROM group_proposals
  WHERE id = v_disbursement.proposal_id AND organization_id = p_organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_PROPOSAL_NOT_FOUND'; END IF;
  IF v_proposal.proposal_type <> 'treasury_disbursement' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PROPOSAL_TYPE_INVALID';
  END IF;
  IF v_proposal.state <> 'approved' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PROPOSAL_NOT_APPROVED';
  END IF;

  SELECT * INTO v_snapshot FROM group_voting_snapshots
  WHERE proposal_id = v_disbursement.proposal_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_SNAPSHOT_MISSING'; END IF;

  -- Clause 3: at least two distinct approving actors. Counted from current votes
  -- so a single member changing their mind repeatedly cannot satisfy it.
  SELECT COUNT(DISTINCT voter_id) INTO v_approver_count
  FROM group_vote_history
  WHERE proposal_id = v_disbursement.proposal_id
    AND choice = 'approve' AND is_current;
  IF v_approver_count < 2 THEN
    RAISE EXCEPTION 'GROUP_TREASURY_INSUFFICIENT_APPROVERS';
  END IF;

  SELECT * INTO v_budget FROM group_treasury_budgets
  WHERE id = v_disbursement.budget_id FOR UPDATE;
  IF v_budget.state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_ACTIVE';
  END IF;

  -- Clause 4: a disclosed low-value band may apply a lower threshold, but only
  -- to amounts inside the band. The basis is recorded either way so the applied
  -- rule is always visible after the fact.
  IF v_budget.low_value_band_minor IS NOT NULL
    AND v_disbursement.amount_minor <= v_budget.low_value_band_minor THEN
    v_threshold_basis := 'low_value_band';
    v_quorum_bps := v_budget.low_value_quorum_bps;
    v_approval_bps := v_budget.low_value_approval_bps;
  ELSE
    v_threshold_basis := 'default';
    v_quorum_bps := v_snapshot.quorum_bps;
    v_approval_bps := v_snapshot.approval_bps;
  END IF;

  -- Clause 2: reserve against funds derived from posted journals, never against
  -- a mutable balance column.
  v_account_id := group_treasury_account_id(p_organization_id, v_disbursement.group_id);
  v_available := group_treasury_available_minor(p_organization_id, v_disbursement.group_id);
  IF v_available < v_disbursement.amount_minor THEN
    RAISE EXCEPTION 'GROUP_TREASURY_INSUFFICIENT_AVAILABLE_FUNDS';
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO group_treasury_reservations(
    organization_id, group_id, budget_id, disbursement_id, source_account_id,
    amount_minor, currency, state, available_minor_at_reserve, expires_at,
    reserved_by, correlation_id
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, v_account_id, v_disbursement.amount_minor,
    v_disbursement.currency, 'active', v_available,
    v_disbursement.execute_until, p_final_checker_id, p_correlation_id
  ) RETURNING id INTO v_reservation_id;

  UPDATE group_treasury_disbursements
  SET state = 'approved',
    final_checker_id = p_final_checker_id,
    approver_count = v_approver_count,
    available_minor_at_approval = v_available,
    quorum_bps_applied = v_quorum_bps,
    approval_bps_applied = v_approval_bps,
    threshold_basis = v_threshold_basis,
    reservation_id = v_reservation_id,
    approved_at = NOW(),
    updated_at = NOW()
  WHERE id = p_disbursement_id;

  UPDATE group_treasury_budgets
  SET committed_minor = committed_minor + v_disbursement.amount_minor,
    updated_at = NOW()
  WHERE id = v_disbursement.budget_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, actor_id, correlation_id, detail
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, 'disbursement.approved', 'requested', 'approved',
    v_disbursement.amount_minor, p_final_checker_id, p_correlation_id,
    jsonb_build_object(
      'threshold_basis', v_threshold_basis,
      'quorum_bps', v_quorum_bps,
      'approval_bps', v_approval_bps,
      'approver_count', v_approver_count,
      'available_minor', v_available,
      'reservation_id', v_reservation_id
    )
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_reservation_id;
END;
$$;
-- Clause 5 and 6. Execution revalidates everything approval relied on, because
-- time passed: the group may have been suspended, the window may have closed,
-- the budget may have been shut, or funds may have moved. Only then does it post
-- the balanced internal journal and consume the reservation exactly once.
CREATE OR REPLACE FUNCTION execute_group_treasury_disbursement(
  p_organization_id UUID,
  p_disbursement_id UUID,
  p_actor_id UUID,
  p_correlation_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_disbursement group_treasury_disbursements;
  v_budget group_treasury_budgets;
  v_reservation group_treasury_reservations;
  v_group groups;
  v_credit_account_id UUID;
  v_group_key TEXT;
  v_journal_id UUID;
  v_lines JSONB;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = p_disbursement_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  -- Idempotent: a repeat call returns the journal already posted rather than
  -- posting a second one.
  IF v_disbursement.state = 'executed' THEN
    RETURN v_disbursement.execution_journal_entry_id;
  END IF;
  IF v_disbursement.state <> 'approved' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_APPROVED';
  END IF;

  -- Revalidate the execution window.
  IF NOW() < v_disbursement.execute_from THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EXECUTION_WINDOW_NOT_OPEN';
  END IF;
  IF NOW() > v_disbursement.execute_until THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EXECUTION_WINDOW_EXPIRED';
  END IF;

  -- Revalidate the group is still able to spend.
  SELECT * INTO v_group FROM groups WHERE id = v_disbursement.group_id;
  IF v_group.lifecycle_state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_GROUP_NOT_ACTIVE';
  END IF;
  -- Revalidate the constitution has not changed under the decision.
  IF v_group.current_constitution_id IS DISTINCT FROM v_disbursement.constitution_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CONSTITUTION_CHANGED';
  END IF;

  SELECT * INTO v_budget FROM group_treasury_budgets
  WHERE id = v_disbursement.budget_id FOR UPDATE;
  IF v_budget.state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_ACTIVE';
  END IF;

  SELECT * INTO v_reservation FROM group_treasury_reservations
  WHERE disbursement_id = p_disbursement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_RESERVATION_MISSING'; END IF;
  IF v_reservation.state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_RESERVATION_NOT_ACTIVE';
  END IF;

  v_group_key := upper(substr(md5(v_disbursement.group_id::TEXT), 1, 16));
  -- Clause 6: internal disbursements post between group and recipient
  -- liabilities. The credit side is the beneficiary's own liability account, so
  -- value is transferred rather than created.
  IF v_disbursement.beneficiary_kind = 'member' THEN
    v_credit_account_id := ensure_wallet_system_account(
      p_organization_id,
      'GROUP.' || v_group_key || '.MEMBER_PAYABLE',
      'Group amounts payable to members', 'liability', 'credit'
    );
  ELSIF v_disbursement.beneficiary_kind = 'project' THEN
    v_credit_account_id := ensure_wallet_system_account(
      p_organization_id,
      'GROUP.' || v_group_key || '.PROJECT_RESTRICTED',
      'Restricted project subscription funding', 'liability', 'credit'
    );
  ELSE
    v_credit_account_id := group_treasury_account_id(
      p_organization_id, v_disbursement.beneficiary_group_id
    );
  END IF;

  IF v_credit_account_id = v_reservation.source_account_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_IS_SOURCE';
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_reservation.source_account_id, 'line_number', 1,
      'side', 'debit', 'amount_minor', v_disbursement.amount_minor,
      'memo', 'Group treasury disbursement'
    ),
    jsonb_build_object(
      'account_id', v_credit_account_id, 'line_number', 2,
      'side', 'credit', 'amount_minor', v_disbursement.amount_minor,
      'memo', 'Group treasury disbursement to ' || v_disbursement.beneficiary_kind
    )
  );
  v_journal_id := post_wallet_journal(
    p_organization_id, 'group.treasury', p_disbursement_id::TEXT,
    'Execute governed group treasury disbursement', v_lines
  );

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  -- Clause 7: the reservation is consumed exactly once. The unique constraint on
  -- consumed_journal_entry_id makes a duplicate consume impossible.
  UPDATE group_treasury_reservations
  SET state = 'consumed', consumed_journal_entry_id = v_journal_id,
    consumed_at = NOW(), updated_at = NOW()
  WHERE id = v_reservation.id;

  UPDATE group_treasury_disbursements
  SET state = 'executed', execution_journal_entry_id = v_journal_id,
    executed_at = NOW(), updated_at = NOW()
  WHERE id = p_disbursement_id;

  -- The commitment becomes actual spend; the envelope total is unchanged.
  UPDATE group_treasury_budgets
  SET committed_minor = committed_minor - v_disbursement.amount_minor,
    disbursed_minor = disbursed_minor + v_disbursement.amount_minor,
    updated_at = NOW()
  WHERE id = v_disbursement.budget_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, actor_id, correlation_id, detail
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, 'disbursement.executed', 'approved', 'executed',
    v_disbursement.amount_minor, p_actor_id, p_correlation_id,
    jsonb_build_object(
      'journal_entry_id', v_journal_id,
      'reservation_id', v_reservation.id,
      'credit_account_id', v_credit_account_id
    )
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_journal_id;
END;
$$;

-- Clause 7: a failed or abandoned disbursement releases its reservation exactly
-- once. The state guard makes a second release a no-op rather than an error, so
-- a retried failure callback cannot free the same funds twice.
CREATE OR REPLACE FUNCTION release_group_treasury_reservation(
  p_organization_id UUID,
  p_disbursement_id UUID,
  p_reason_code TEXT,
  p_actor_id UUID,
  p_correlation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_disbursement group_treasury_disbursements;
  v_reservation group_treasury_reservations;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = p_disbursement_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  IF v_disbursement.state = 'executed' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_ALREADY_EXECUTED';
  END IF;

  SELECT * INTO v_reservation FROM group_treasury_reservations
  WHERE disbursement_id = p_disbursement_id FOR UPDATE;
  IF NOT FOUND OR v_reservation.state <> 'active' THEN
    RETURN FALSE;
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE group_treasury_reservations
  SET state = 'released', release_reason_code = p_reason_code,
    released_at = NOW(), updated_at = NOW()
  WHERE id = v_reservation.id;

  UPDATE group_treasury_disbursements
  SET state = 'cancelled', settled_state_at = NOW(), updated_at = NOW()
  WHERE id = p_disbursement_id;

  UPDATE group_treasury_budgets
  SET committed_minor = committed_minor - v_reservation.amount_minor,
    updated_at = NOW()
  WHERE id = v_disbursement.budget_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, reason_code, actor_id, correlation_id
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, 'reservation.released', v_disbursement.state, 'cancelled',
    v_reservation.amount_minor, p_reason_code, p_actor_id, p_correlation_id
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN TRUE;
END;
$$;
-- Corrects an executed disbursement by posting a compensating journal rather than
-- editing history. The original journal is never touched.
CREATE OR REPLACE FUNCTION reverse_group_treasury_disbursement(
  p_organization_id UUID,
  p_disbursement_id UUID,
  p_reason_code TEXT,
  p_actor_id UUID,
  p_correlation_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_disbursement group_treasury_disbursements;
  v_reservation group_treasury_reservations;
  v_original_lines RECORD;
  v_journal_id UUID;
  v_lines JSONB;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = p_disbursement_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  IF v_disbursement.state <> 'executed' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_EXECUTED';
  END IF;

  SELECT * INTO v_reservation FROM group_treasury_reservations
  WHERE disbursement_id = p_disbursement_id;

  -- Mirror the original entry with the sides swapped.
  SELECT
    MAX(CASE WHEN side = 'debit' THEN account_id END) AS debit_account_id,
    MAX(CASE WHEN side = 'credit' THEN account_id END) AS credit_account_id
  INTO v_original_lines
  FROM journal_lines
  WHERE journal_entry_id = v_disbursement.execution_journal_entry_id;

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_original_lines.credit_account_id, 'line_number', 1,
      'side', 'debit', 'amount_minor', v_disbursement.amount_minor,
      'memo', 'Reverse group treasury disbursement'
    ),
    jsonb_build_object(
      'account_id', v_original_lines.debit_account_id, 'line_number', 2,
      'side', 'credit', 'amount_minor', v_disbursement.amount_minor,
      'memo', 'Restore group treasury funds: ' || p_reason_code
    )
  );
  v_journal_id := post_wallet_journal(
    p_organization_id, 'group.treasury', p_disbursement_id::TEXT || ':reversal',
    'Reverse governed group treasury disbursement', v_lines
  );

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE group_treasury_disbursements
  SET state = 'reversed', reversal_journal_entry_id = v_journal_id,
    settled_state_at = NOW(), updated_at = NOW()
  WHERE id = p_disbursement_id;

  UPDATE group_treasury_budgets
  SET disbursed_minor = disbursed_minor - v_disbursement.amount_minor,
    updated_at = NOW()
  WHERE id = v_disbursement.budget_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, reason_code, actor_id, correlation_id,
    detail
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, 'disbursement.reversed', 'executed', 'reversed',
    v_disbursement.amount_minor, p_reason_code, p_actor_id, p_correlation_id,
    jsonb_build_object('reversal_journal_entry_id', v_journal_id)
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_journal_id;
END;
$$;

-- Tenant isolation. Reads are scoped to the caller's organization; all writes go
-- through the engine functions above, which run as SECURITY DEFINER.
DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'group_treasury_budgets', 'group_treasury_disbursements',
    'group_treasury_reservations', 'group_treasury_events'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', v_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I', v_table);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT '
      'USING (has_active_organization_membership(organization_id))', v_table
    );
    EXECUTE format('REVOKE ALL ON %I FROM PUBLIC, anon, authenticated', v_table);
    EXECUTE format('GRANT SELECT ON %I TO service_role', v_table);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I FROM service_role', v_table);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION group_treasury_account_id(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION group_treasury_available_minor(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION group_treasury_checker_permitted(UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION activate_group_treasury_budget(UUID, UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_group_treasury_disbursement(
  UUID, UUID, UUID, UUID, TEXT, UUID, UUID, UUID, BIGINT, VARCHAR, TEXT, TEXT,
  TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_group_treasury_disbursement(UUID, UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION execute_group_treasury_disbursement(UUID, UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION release_group_treasury_reservation(UUID, UUID, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION reverse_group_treasury_disbursement(UUID, UUID, TEXT, UUID, UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION group_treasury_available_minor(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION group_treasury_checker_permitted(UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION activate_group_treasury_budget(UUID, UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION request_group_treasury_disbursement(
  UUID, UUID, UUID, UUID, TEXT, UUID, UUID, UUID, BIGINT, VARCHAR, TEXT, TEXT,
  TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION approve_group_treasury_disbursement(UUID, UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION execute_group_treasury_disbursement(UUID, UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION release_group_treasury_reservation(UUID, UUID, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION reverse_group_treasury_disbursement(UUID, UUID, TEXT, UUID, UUID) TO service_role;



