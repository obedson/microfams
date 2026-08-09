-- GT-06B: external provider disbursements, provider timeout recovery, and
-- reconciliation of late payout outcomes.
--
-- GT-06A moved money that never left the ledger: a disbursement executed and a
-- balanced internal journal posted in the same transaction. An external payout
-- cannot work that way. The money is handed to a provider whose outcome is not
-- known synchronously, so this slice adds the states and the deferred-posting
-- accounting that gap requires:
--
--   approved --begin--> disbursing --success--> executed
--                            \---- failure/timeout ----> failed
--
-- Option B (deferred posting) is the accounting model. `begin` creates and
-- submits a provider payout but posts NO journal and leaves the reservation
-- active: the group's money is still committed but has not left the treasury on
-- the ledger. Only a confirmed provider success posts the journal (DEBIT the
-- group treasury liability, CREDIT an external payout clearing asset), consumes
-- the reservation exactly once, and turns the budget commitment into spend. A
-- confirmed failure or a timeout that the provider later declines releases the
-- reservation and posts nothing — no money moved, so no journal may exist. A
-- provider that reports success AFTER the payout was already failed is a
-- reconciliation exception recorded without repaying, never a silent second
-- disbursement.
--
-- The shared provider-neutral payout stack (create_payout_orchestration.sql)
-- owns the payout row and its transition graph; this slice adds a third
-- source_type, 'group_treasury', and a typed FK, exactly as BS-08 added
-- 'booking_settlement'. An external destination is a verified beneficiary held
-- in a new group-scoped registry that mirrors booking_payout_beneficiaries:
-- custody and provider verification live there, never on the disbursement.
--
-- The shared adapter settles NGN only, so an external disbursement inherits that
-- constraint; internal disbursements remain multi-currency at the budget level.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Group-scoped verified beneficiary registry.
--
-- Mirrors booking_payout_beneficiaries: the destination is encrypted at rest,
-- fingerprinted for equality without disclosure, and masked for display. A
-- destination is proposed by one actor and verified by a different one who holds
-- the treasury approve permission, so custody separation is structural. Unlike
-- BS-08 — where a supplier organization has one destination — a group pays many
-- external vendors, so the verified-uniqueness key includes the destination
-- fingerprint: many distinct verified destinations per group, but never two
-- verified rows for the same destination and provider.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS group_treasury_beneficiaries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  -- Set only when the external account belongs to a known member, so separation
  -- of duties can still exclude a beneficiary who is also a platform user.
  beneficiary_user_id UUID REFERENCES users(id),
  destination_ciphertext TEXT NOT NULL
    CHECK (length(destination_ciphertext) BETWEEN 40 AND 4096),
  destination_fingerprint VARCHAR(64) NOT NULL
    CHECK (destination_fingerprint ~ '^[a-f0-9]{64}$'),
  -- Held to 40 so it fits payouts.beneficiary_masked without truncation.
  destination_masked TEXT NOT NULL CHECK (length(destination_masked) BETWEEN 4 AND 40),
  account_name_masked TEXT NOT NULL CHECK (length(account_name_masked) BETWEEN 2 AND 120),
  provider_name TEXT NOT NULL CHECK (provider_name ~ '^[a-z][a-z0-9_-]{1,31}$'),
  provider_environment TEXT NOT NULL
    CHECK (provider_environment IN ('deterministic', 'sandbox', 'live')),
  verification_reference TEXT NOT NULL
    CHECK (length(verification_reference) BETWEEN 4 AND 200),
  state TEXT NOT NULL DEFAULT 'pending_approval' CHECK (state IN (
    'pending_approval', 'verified', 'retired', 'rejected', 'suspended'
  )),
  proposed_by UUID NOT NULL REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  approval_reason TEXT CHECK (
    approval_reason IS NULL OR length(btrim(approval_reason)) BETWEEN 10 AND 1000
  ),
  approved_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  -- A verified destination carries its approver; a pending one has none yet.
  CHECK (
    (state = 'pending_approval' AND approved_at IS NULL AND approved_by IS NULL)
    OR (state = 'verified' AND approved_at IS NOT NULL AND approved_by IS NOT NULL)
    OR state IN ('retired', 'rejected', 'suspended')
  ),
  -- The verifier is never the proposer.
  CHECK (approved_by IS NULL OR approved_by <> proposed_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_treasury_verified_beneficiary
  ON group_treasury_beneficiaries(
    organization_id, group_id, provider_name, provider_environment, destination_fingerprint
  ) WHERE state = 'verified';
CREATE INDEX IF NOT EXISTS idx_group_treasury_beneficiary_group
  ON group_treasury_beneficiaries(organization_id, group_id, state, created_at);

-- ---------------------------------------------------------------------------
-- 2. Late-success reconciliation exceptions.
--
-- A provider that confirms success after a payout was failed or cancelled must
-- be recorded, not replayed. This table is the evidence that the money left the
-- provider even though the ledger already released the reservation; settling it
-- is a manual reconciliation, never an automatic second debit.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS group_treasury_late_payout_exceptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  disbursement_id UUID NOT NULL
    REFERENCES group_treasury_disbursements(id) ON DELETE RESTRICT,
  payout_id UUID NOT NULL REFERENCES payouts(id) ON DELETE RESTRICT,
  provider_reference TEXT NOT NULL CHECK (length(provider_reference) BETWEEN 1 AND 160),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  beneficiary_fingerprint VARCHAR(64) NOT NULL
    CHECK (beneficiary_fingerprint ~ '^[a-f0-9]{64}$'),
  evidence_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(evidence_snapshot) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (payout_id, provider_reference)
);

-- ---------------------------------------------------------------------------
-- 3. Extend the shared payout row with the group_treasury source.
--
-- Additive, exactly as BS-08 added 'booking_settlement'. The source-shape CHECK
-- is exhaustive, so it must be dropped and re-added with the third branch — a
-- plain ADD COLUMN would leave the new source unrepresented.
-- ---------------------------------------------------------------------------
ALTER TABLE payouts
  ADD COLUMN IF NOT EXISTS group_treasury_disbursement_id UUID
    REFERENCES group_treasury_disbursements(id);

-- Drop the legacy source_type value list whatever its auto-generated name, then
-- re-add it (idempotently) including 'group_treasury'. The scan is narrowed so
-- it never matches the source-shape CHECK, which also mentions the same values.
DO $$
DECLARE v_name TEXT;
BEGIN
  FOR v_name IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'payouts'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%source_type%'
      AND pg_get_constraintdef(oid) LIKE '%booking_settlement%'
      AND pg_get_constraintdef(oid) NOT LIKE '%IS NOT NULL%'
      AND pg_get_constraintdef(oid) NOT LIKE '%group_treasury%'
  LOOP
    EXECUTE format('ALTER TABLE payouts DROP CONSTRAINT %I', v_name);
  END LOOP;
END $$;
ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_source_type_check;
ALTER TABLE payouts ADD CONSTRAINT payouts_source_type_check
  CHECK (source_type IN ('wallet_withdrawal', 'booking_settlement', 'group_treasury'));

ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_source_shape;
ALTER TABLE payouts ADD CONSTRAINT payouts_source_shape CHECK (
  (
    source_type = 'wallet_withdrawal'
    AND withdrawal_request_id IS NOT NULL
    AND reservation_id IS NOT NULL
    AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL
    AND group_treasury_disbursement_id IS NULL
    AND source_id = withdrawal_request_id
  )
  OR (
    source_type = 'booking_settlement'
    AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL
    AND booking_settlement_release_id IS NOT NULL
    AND booking_payout_beneficiary_id IS NOT NULL
    AND group_treasury_disbursement_id IS NULL
    AND source_id = booking_settlement_release_id
  )
  OR (
    source_type = 'group_treasury'
    AND withdrawal_request_id IS NULL
    AND reservation_id IS NULL
    AND booking_settlement_release_id IS NULL
    AND booking_payout_beneficiary_id IS NULL
    AND group_treasury_disbursement_id IS NOT NULL
    AND source_id = group_treasury_disbursement_id
  )
);

-- ---------------------------------------------------------------------------
-- 4. Extend the disbursement row for the external channel.
--
-- The 'external' channel, the 'disbursing'/'failed' states, and the external
-- beneficiary and payout links. The state/journal coupling CHECKs from GT-06A
-- already hold: 'disbursing' and 'failed' carry no execution journal (they are
-- not in the executed/reversed set) and no executed_at, which is exactly right —
-- disbursing has a payout but no posting, failed has neither.
-- ---------------------------------------------------------------------------
ALTER TABLE group_treasury_disbursements
  ADD COLUMN IF NOT EXISTS external_beneficiary_id UUID
    REFERENCES group_treasury_beneficiaries(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS payout_id UUID REFERENCES payouts(id) ON DELETE RESTRICT;

ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_channel_check;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_channel_check
  CHECK (channel IN ('internal', 'external'));

ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_beneficiary_kind_check;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_beneficiary_kind_check
  CHECK (beneficiary_kind IN ('member', 'group', 'project', 'external'));

ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_state_check;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_state_check
  CHECK (state IN (
    'requested', 'approved', 'disbursing', 'executed',
    'rejected', 'cancelled', 'expired', 'failed', 'reversed'
  ));

-- Replace the beneficiary-identity CHECK (found by definition, since GT-06A gave
-- it an auto name) with one that adds the external branch. The external branch
-- names a registry row and no on-platform beneficiary destination.
DO $$
DECLARE v_name TEXT;
BEGIN
  SELECT conname INTO v_name FROM pg_constraint
  WHERE conrelid = 'group_treasury_disbursements'::regclass AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%beneficiary_kind%'
    AND pg_get_constraintdef(oid) LIKE '%beneficiary_member_id%'
    AND pg_get_constraintdef(oid) LIKE '%beneficiary_project_id%'
    AND pg_get_constraintdef(oid) LIKE '%beneficiary_group_id%'
    AND pg_get_constraintdef(oid) NOT LIKE '%external%';
  IF v_name IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE group_treasury_disbursements DROP CONSTRAINT %I', v_name
    );
  END IF;
END $$;
ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_beneficiary_identity;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_beneficiary_identity CHECK (
    (beneficiary_kind = 'member' AND beneficiary_member_id IS NOT NULL
      AND beneficiary_user_id IS NOT NULL AND beneficiary_group_id IS NULL
      AND beneficiary_project_id IS NULL AND external_beneficiary_id IS NULL)
    OR (beneficiary_kind = 'group' AND beneficiary_group_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_project_id IS NULL AND external_beneficiary_id IS NULL)
    OR (beneficiary_kind = 'project' AND beneficiary_project_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_group_id IS NULL AND external_beneficiary_id IS NULL)
    OR (beneficiary_kind = 'external' AND external_beneficiary_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_group_id IS NULL
      AND beneficiary_project_id IS NULL)
  );

-- Channel and kind agree, an external channel always names a registry row, and
-- only an external disbursement may carry a provider payout.
ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_channel_consistency;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_channel_consistency
  CHECK ((channel = 'external') = (beneficiary_kind = 'external'));
ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_external_link;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_external_link
  CHECK ((external_beneficiary_id IS NOT NULL) = (channel = 'external'));
ALTER TABLE group_treasury_disbursements
  DROP CONSTRAINT IF EXISTS group_treasury_disbursements_payout_link;
ALTER TABLE group_treasury_disbursements
  ADD CONSTRAINT group_treasury_disbursements_payout_link
  CHECK (payout_id IS NULL OR channel = 'external');
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_treasury_disbursement_payout
  ON group_treasury_disbursements(payout_id) WHERE payout_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Engine-lock the two new evidence tables.
--
-- Reuses protect_group_treasury_evidence(): both tables are writable only while
-- microfams.group_treasury_engine = 'on', which the functions below set.
--
-- The GT-06A body carried the budget-draft carve-out as a flat
-- `TG_TABLE_NAME = 'group_treasury_budgets' AND ... AND OLD.state = 'draft'`.
-- Postgres resolves OLD.state against the triggering table's row type at plan
-- time, before the AND can short-circuit. group_treasury_late_payout_exceptions
-- has no state column, so on the refusal path (engine off) the flat form raises
-- an internal "record old has no field state" instead of the clean
-- GROUP_TREASURY_ENGINE_REQUIRED. Nesting the OLD.state test so it is only
-- planned for the budgets table restores the intended refusal for every locked
-- table regardless of its columns; the engine-on early return is unchanged.
CREATE OR REPLACE FUNCTION protect_group_treasury_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.group_treasury_engine', TRUE) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  -- A budget is still editable while it is a draft; once active it is governed.
  IF TG_TABLE_NAME = 'group_treasury_budgets' AND TG_OP = 'UPDATE' THEN
    IF OLD.state = 'draft' THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'GROUP_TREASURY_ENGINE_REQUIRED';
END;
$$;

-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS protect_group_treasury_beneficiaries
  ON group_treasury_beneficiaries;
CREATE TRIGGER protect_group_treasury_beneficiaries
  BEFORE INSERT OR UPDATE OR DELETE ON group_treasury_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();
DROP TRIGGER IF EXISTS protect_group_treasury_late_payout_exceptions
  ON group_treasury_late_payout_exceptions;
CREATE TRIGGER protect_group_treasury_late_payout_exceptions
  BEFORE INSERT OR UPDATE OR DELETE ON group_treasury_late_payout_exceptions
  FOR EACH ROW EXECUTE FUNCTION protect_group_treasury_evidence();

-- ---------------------------------------------------------------------------
-- 6. External payout clearing account.
--
-- The credit side of a confirmed external disbursement. An asset that holds
-- value in transit to the provider: crediting it on success reduces the
-- platform float as the treasury liability is debited. wallet_account_balance_minor
-- reads liability/credit accounts only, so the treasury figure that
-- group_treasury_available_minor derives stays correct after the debit; this
-- clearing asset is reconciled against provider settlement, not read as a
-- treasury balance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION group_treasury_external_clearing_account_id(
  p_organization_id UUID, p_group_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_group_key TEXT;
BEGIN
  v_group_key := upper(substr(md5(p_group_id::TEXT), 1, 16));
  RETURN ensure_wallet_system_account(
    p_organization_id, 'GROUP.' || v_group_key || '.EXTERNAL_PAYOUT_CLEARING',
    'Group treasury external payout provider clearing', 'asset', 'debit'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Register a proposed external beneficiary (maker).
--
-- The service layer owns the crypto: it passes the ciphertext, fingerprint, and
-- masks. This stores them as pending_approval and is idempotent on
-- (organization_id, idempotency_key). Verification is a separate checker action.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION register_group_treasury_beneficiary(
  p_organization_id UUID,
  p_group_id UUID,
  p_actor_id UUID,
  p_beneficiary_user_id UUID,
  p_destination_ciphertext TEXT,
  p_destination_fingerprint TEXT,
  p_destination_masked TEXT,
  p_account_name_masked TEXT,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_verification_reference TEXT,
  p_idempotency_key TEXT,
  p_request_hash TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_group groups;
  v_existing group_treasury_beneficiaries;
  v_beneficiary group_treasury_beneficiaries;
  v_previous TEXT;
BEGIN
  IF p_organization_id IS NULL OR p_group_id IS NULL OR p_actor_id IS NULL
    OR p_correlation_id IS NULL
    OR p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic', 'sandbox', 'live')
    OR p_destination_fingerprint !~ '^[a-f0-9]{64}$'
    OR p_request_hash !~ '^[a-f0-9]{64}$'
    OR length(COALESCE(p_idempotency_key, '')) NOT BETWEEN 8 AND 160
  THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_INVALID';
  END IF;

  SELECT * INTO v_group FROM groups
  WHERE id = p_group_id AND organization_id = p_organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_GROUP_NOT_FOUND'; END IF;

  SELECT * INTO v_existing FROM group_treasury_beneficiaries
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> lower(p_request_hash) THEN
      RAISE EXCEPTION 'GROUP_TREASURY_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN to_jsonb(v_existing);
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO group_treasury_beneficiaries(
    organization_id, group_id, beneficiary_user_id, destination_ciphertext,
    destination_fingerprint, destination_masked, account_name_masked,
    provider_name, provider_environment, verification_reference, state,
    proposed_by, idempotency_key, request_hash, correlation_id
  ) VALUES (
    p_organization_id, p_group_id, p_beneficiary_user_id, p_destination_ciphertext,
    lower(p_destination_fingerprint), p_destination_masked, p_account_name_masked,
    p_provider_name, p_provider_environment, p_verification_reference,
    'pending_approval', p_actor_id, p_idempotency_key, lower(p_request_hash),
    p_correlation_id
  ) RETURNING * INTO v_beneficiary;

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN to_jsonb(v_beneficiary);
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Verify a pending beneficiary (checker).
--
-- The verifier must be a different person from the proposer, must not be the
-- named beneficiary user, and must hold the treasury approve permission — the
-- same authority GT-06A requires of a disbursement's final checker. The partial
-- unique index refuses a second verified row for the same destination.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_group_treasury_beneficiary(
  p_organization_id UUID,
  p_group_id UUID,
  p_beneficiary_id UUID,
  p_checker_id UUID,
  p_approval_reason TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_beneficiary group_treasury_beneficiaries;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_beneficiary FROM group_treasury_beneficiaries
  WHERE id = p_beneficiary_id AND organization_id = p_organization_id
    AND group_id = p_group_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_FOUND'; END IF;
  IF v_beneficiary.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_PENDING';
  END IF;
  IF p_checker_id = v_beneficiary.proposed_by THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK';
  END IF;
  IF v_beneficiary.beneficiary_user_id IS NOT NULL
    AND p_checker_id = v_beneficiary.beneficiary_user_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_CHECKER_IS_BENEFICIARY';
  END IF;
  IF NOT group_treasury_checker_permitted(p_organization_id, p_group_id, p_checker_id) THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHECKER_NOT_PERMITTED';
  END IF;
  IF p_approval_reason IS NULL
    OR length(btrim(p_approval_reason)) NOT BETWEEN 10 AND 1000 THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_REASON_REQUIRED';
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE group_treasury_beneficiaries
  SET state = 'verified', approved_by = p_checker_id,
    approval_reason = btrim(p_approval_reason), approved_at = NOW(), updated_at = NOW()
  WHERE id = p_beneficiary_id RETURNING * INTO v_beneficiary;

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN to_jsonb(v_beneficiary);
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Reject a pending beneficiary (checker).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reject_group_treasury_beneficiary(
  p_organization_id UUID,
  p_group_id UUID,
  p_beneficiary_id UUID,
  p_checker_id UUID,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_beneficiary group_treasury_beneficiaries;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_beneficiary FROM group_treasury_beneficiaries
  WHERE id = p_beneficiary_id AND organization_id = p_organization_id
    AND group_id = p_group_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_FOUND'; END IF;
  IF v_beneficiary.state <> 'pending_approval' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_PENDING';
  END IF;
  IF p_checker_id = v_beneficiary.proposed_by THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_MAKER_CANNOT_CHECK';
  END IF;
  IF NOT group_treasury_checker_permitted(p_organization_id, p_group_id, p_checker_id) THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHECKER_NOT_PERMITTED';
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE group_treasury_beneficiaries
  SET state = 'rejected', updated_at = NOW()
  WHERE id = p_beneficiary_id RETURNING * INTO v_beneficiary;

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN to_jsonb(v_beneficiary);
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Request an external disbursement.
--
-- Separate from request_group_treasury_disbursement because the external path
-- names a verified beneficiary instead of an on-platform destination. It reuses
-- the same budget ceiling and idempotency rules and, once requested, goes
-- through the same approve_group_treasury_disbursement (which reserves funds and
-- enforces separation of duties against beneficiary_user_id). Idempotent on
-- (organization_id, idempotency_key).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_group_treasury_external_disbursement(
  p_organization_id UUID,
  p_group_id UUID,
  p_budget_id UUID,
  p_proposal_id UUID,
  p_external_beneficiary_id UUID,
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
  v_beneficiary group_treasury_beneficiaries;
  v_existing UUID;
  v_disbursement_id UUID;
  v_previous TEXT;
BEGIN
  SELECT id INTO v_existing FROM group_treasury_disbursements
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  -- The shared adapter settles NGN only.
  IF p_currency <> 'NGN' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EXTERNAL_CURRENCY_UNSUPPORTED';
  END IF;

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
  IF v_budget.committed_minor + v_budget.disbursed_minor + p_amount_minor
    > v_budget.ceiling_minor THEN
    RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_CEILING_EXCEEDED';
  END IF;

  -- The destination must be a verified beneficiary of this group. Its provider
  -- pairing is pinned at begin time, not here.
  SELECT * INTO v_beneficiary FROM group_treasury_beneficiaries
  WHERE id = p_external_beneficiary_id
    AND organization_id = p_organization_id AND group_id = p_group_id
    AND state = 'verified';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED'; END IF;

  -- Clause 3: a beneficiary who is a known member cannot request their own pay.
  IF v_beneficiary.beneficiary_user_id IS NOT NULL
    AND v_beneficiary.beneficiary_user_id = p_requested_by THEN
    RAISE EXCEPTION 'GROUP_TREASURY_SELF_BENEFICIARY_FORBIDDEN';
  END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO group_treasury_disbursements(
    organization_id, group_id, budget_id, constitution_id, proposal_id,
    channel, beneficiary_kind, beneficiary_user_id, external_beneficiary_id,
    amount_minor, currency, purpose, evidence_uri, execute_from, execute_until,
    state, requested_by, idempotency_key, correlation_id
  ) VALUES (
    p_organization_id, p_group_id, p_budget_id, v_budget.constitution_id,
    p_proposal_id, 'external', 'external', v_beneficiary.beneficiary_user_id,
    p_external_beneficiary_id, p_amount_minor, p_currency, p_purpose,
    p_evidence_uri, p_execute_from, p_execute_until, 'requested', p_requested_by,
    p_idempotency_key, p_correlation_id
  ) RETURNING id INTO v_disbursement_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    to_state, amount_minor, actor_id, correlation_id, detail
  ) VALUES (
    p_organization_id, p_group_id, p_budget_id, v_disbursement_id,
    'disbursement.requested', 'requested', p_amount_minor, p_requested_by,
    p_correlation_id,
    jsonb_build_object('channel', 'external', 'beneficiary_id', p_external_beneficiary_id)
  );

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN v_disbursement_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11. Guard internal execution against external disbursements.
--
-- CREATE OR REPLACE of the GT-06A function with one added guard: internal
-- execution must never run on an external disbursement, whose posting is
-- deferred to confirmed provider success. Without the guard a misrouted call
-- would try to resolve a NULL beneficiary account and fail with a raw DB error
-- instead of a named one. The body is otherwise identical to GT-06A.
-- ---------------------------------------------------------------------------
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
  -- GT-06B: internal execution posts synchronously; an external disbursement
  -- settles through the provider payout path, never here.
  IF v_disbursement.channel <> 'internal' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHANNEL_NOT_INTERNAL';
  END IF;
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

  UPDATE group_treasury_reservations
  SET state = 'consumed', consumed_journal_entry_id = v_journal_id,
    consumed_at = NOW(), updated_at = NOW()
  WHERE id = v_reservation.id;

  UPDATE group_treasury_disbursements
  SET state = 'executed', execution_journal_entry_id = v_journal_id,
    executed_at = NOW(), updated_at = NOW()
  WHERE id = p_disbursement_id;

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

-- ---------------------------------------------------------------------------
-- 12. Begin an external disbursement: create and reserve the provider payout.
--
-- Revalidates the approval snapshot exactly as internal execution does, then
-- creates a payout row linked to the disbursement and moves the disbursement to
-- 'disbursing'. Posts NO journal — Option B defers posting to confirmed success.
-- The reservation stays active: the money is still committed. Idempotent: a
-- repeat while already disbursing returns the in-flight payout.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION begin_group_treasury_external_disbursement(
  p_organization_id UUID,
  p_disbursement_id UUID,
  p_actor_id UUID,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_correlation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_disbursement group_treasury_disbursements;
  v_budget group_treasury_budgets;
  v_reservation group_treasury_reservations;
  v_group groups;
  v_beneficiary group_treasury_beneficiaries;
  v_payout payouts;
  v_hash TEXT;
  v_previous_payout TEXT;
  v_previous_treasury TEXT;
BEGIN
  IF p_provider_name !~ '^[a-z][a-z0-9_-]{1,31}$'
    OR p_provider_environment NOT IN ('deterministic', 'sandbox', 'live') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PROVIDER_INVALID';
  END IF;

  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = p_disbursement_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  IF v_disbursement.channel <> 'external' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_NOT_EXTERNAL';
  END IF;
  -- Idempotent: the payout is already in flight.
  IF v_disbursement.state = 'disbursing' AND v_disbursement.payout_id IS NOT NULL THEN
    SELECT * INTO v_payout FROM payouts WHERE id = v_disbursement.payout_id;
    RETURN jsonb_build_object(
      'payout_id', v_payout.id, 'internal_reference', v_payout.internal_reference,
      'request_hash', v_payout.request_hash, 'amount_minor', v_payout.amount_minor,
      'currency', v_payout.currency, 'state', v_payout.state,
      'destination_masked', v_payout.beneficiary_masked,
      'provider_name', v_payout.provider_name,
      'provider_environment', v_payout.provider_environment,
      'beneficiary_fingerprint', v_payout.beneficiary_fingerprint,
      'idempotency_replay', TRUE
    );
  END IF;
  IF v_disbursement.state <> 'approved' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_APPROVED';
  END IF;

  -- Revalidate exactly as internal execution does.
  IF NOW() < v_disbursement.execute_from THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EXECUTION_WINDOW_NOT_OPEN';
  END IF;
  IF NOW() > v_disbursement.execute_until THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EXECUTION_WINDOW_EXPIRED';
  END IF;
  SELECT * INTO v_group FROM groups WHERE id = v_disbursement.group_id;
  IF v_group.lifecycle_state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_GROUP_NOT_ACTIVE';
  END IF;
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

  -- The destination must still be a verified beneficiary for the named provider.
  SELECT * INTO v_beneficiary FROM group_treasury_beneficiaries
  WHERE id = v_disbursement.external_beneficiary_id
    AND organization_id = p_organization_id AND group_id = v_disbursement.group_id
    AND provider_name = p_provider_name
    AND provider_environment = p_provider_environment
    AND state = 'verified';
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED'; END IF;

  v_hash := encode(digest(convert_to(concat_ws('|',
    p_disbursement_id::TEXT, p_organization_id::TEXT, v_beneficiary.id::TEXT,
    p_provider_name, p_provider_environment, v_disbursement.amount_minor::TEXT,
    v_disbursement.currency
  ), 'UTF8'), 'sha256'), 'hex');

  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_treasury := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO payouts(
    organization_id, withdrawal_request_id, reservation_id, internal_reference,
    idempotency_key, request_hash, provider_name, provider_environment, currency,
    amount_minor, fee_amount_minor, beneficiary_fingerprint, beneficiary_masked,
    state, correlation_id, actor_id, source_type, source_id,
    group_treasury_disbursement_id
  ) VALUES (
    p_organization_id, NULL, NULL,
    'GTP-' || replace(p_disbursement_id::TEXT, '-', ''),
    'gtp-' || replace(p_disbursement_id::TEXT, '-', ''), v_hash,
    p_provider_name, p_provider_environment, v_disbursement.currency,
    v_disbursement.amount_minor, 0, v_beneficiary.destination_fingerprint,
    v_beneficiary.destination_masked, 'reserved', p_correlation_id, p_actor_id,
    'group_treasury', p_disbursement_id, p_disbursement_id
  ) RETURNING * INTO v_payout;

  UPDATE group_treasury_disbursements
  SET state = 'disbursing', payout_id = v_payout.id, updated_at = NOW()
  WHERE id = p_disbursement_id;

  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, actor_id, correlation_id, detail
  ) VALUES (
    p_organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    p_disbursement_id, 'disbursement.disbursing', 'approved', 'disbursing',
    v_disbursement.amount_minor, p_actor_id, p_correlation_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'beneficiary_id', v_beneficiary.id,
      'provider_name', p_provider_name, 'provider_environment', p_provider_environment
    )
  );

  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE);
  PERFORM set_config('microfams.group_treasury_engine', COALESCE(v_previous_treasury, ''), TRUE);

  RETURN jsonb_build_object(
    'payout_id', v_payout.id, 'internal_reference', v_payout.internal_reference,
    'request_hash', v_hash, 'amount_minor', v_payout.amount_minor,
    'currency', v_payout.currency, 'state', v_payout.state,
    'destination_masked', v_payout.beneficiary_masked,
    'provider_name', p_provider_name, 'provider_environment', p_provider_environment,
    'beneficiary_fingerprint', v_beneficiary.destination_fingerprint,
    'idempotency_replay', FALSE
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 13. Confirmed provider success: post, consume, and settle.
--
-- Option B posting happens here and only here. Debit the group treasury
-- liability, credit the external payout clearing asset — value leaves both the
-- group's claim and the platform float. Consume the reservation exactly once
-- (the unique constraint on consumed_journal_entry_id makes a double consume
-- impossible), turn the budget commitment into spend, and move the disbursement
-- to executed. Idempotent: a repeat once succeeded returns the payout unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION succeed_group_treasury_payout(
  p_payout_id UUID,
  p_internal_reference TEXT,
  p_provider_reference TEXT,
  p_amount_minor BIGINT,
  p_currency TEXT,
  p_beneficiary_fingerprint TEXT,
  p_organization_id UUID,
  p_provider_name TEXT,
  p_provider_environment TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_disbursement group_treasury_disbursements;
  v_reservation group_treasury_reservations;
  v_treasury_account UUID;
  v_clearing_account UUID;
  v_journal_id UUID;
  v_lines JSONB;
  v_previous_payout TEXT;
  v_previous_treasury TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'group_treasury' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_NOT_FOUND';
  END IF;
  -- Provider identity must match the stored payout exactly, so a success cannot
  -- be applied with a different amount, currency, or destination than reserved.
  IF p_internal_reference <> v_payout.internal_reference
    OR p_provider_reference IS NULL
    OR length(p_provider_reference) NOT BETWEEN 1 AND 160
    OR p_amount_minor <> v_payout.amount_minor
    OR upper(p_currency) <> v_payout.currency
    OR lower(p_beneficiary_fingerprint) <> v_payout.beneficiary_fingerprint
    OR p_organization_id <> v_payout.organization_id
    OR p_provider_name <> v_payout.provider_name
    OR p_provider_environment <> v_payout.provider_environment THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_PROVIDER_MISMATCH';
  END IF;
  IF v_payout.provider_reference IS NOT NULL
    AND v_payout.provider_reference <> p_provider_reference THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_PROVIDER_MISMATCH';
  END IF;
  IF v_payout.state = 'succeeded' THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'succeeded') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_TRANSITION_INVALID';
  END IF;

  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = v_payout.group_treasury_disbursement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  IF v_disbursement.state <> 'disbursing' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_DISBURSING';
  END IF;
  SELECT * INTO v_reservation FROM group_treasury_reservations
  WHERE disbursement_id = v_disbursement.id FOR UPDATE;
  IF NOT FOUND OR v_reservation.state <> 'active' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_RESERVATION_NOT_ACTIVE';
  END IF;

  v_treasury_account := group_treasury_account_id(p_organization_id, v_disbursement.group_id);
  IF v_treasury_account <> v_reservation.source_account_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_SOURCE_MISMATCH';
  END IF;
  v_clearing_account := group_treasury_external_clearing_account_id(
    p_organization_id, v_disbursement.group_id
  );

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_treasury_account, 'line_number', 1, 'side', 'debit',
      'amount_minor', v_disbursement.amount_minor,
      'memo', 'Group treasury external disbursement'
    ),
    jsonb_build_object(
      'account_id', v_clearing_account, 'line_number', 2, 'side', 'credit',
      'amount_minor', v_disbursement.amount_minor,
      'memo', 'External payout provider clearing'
    )
  );
  v_journal_id := post_wallet_journal(
    p_organization_id, 'group.treasury.payout', v_payout.id::TEXT,
    'Settle governed group treasury external disbursement', v_lines
  );

  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_treasury := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE payouts
  SET state = 'succeeded', provider_reference = p_provider_reference,
    success_journal_entry_id = v_journal_id, terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_payout.id RETURNING * INTO v_payout;

  UPDATE group_treasury_reservations
  SET state = 'consumed', consumed_journal_entry_id = v_journal_id,
    consumed_at = NOW(), updated_at = NOW()
  WHERE id = v_reservation.id;

  UPDATE group_treasury_disbursements
  SET state = 'executed', execution_journal_entry_id = v_journal_id,
    executed_at = NOW(), updated_at = NOW()
  WHERE id = v_disbursement.id;

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
    v_disbursement.id, 'disbursement.executed', 'disbursing', 'executed',
    v_disbursement.amount_minor, v_payout.actor_id, v_disbursement.correlation_id,
    jsonb_build_object(
      'journal_entry_id', v_journal_id, 'payout_id', v_payout.id,
      'provider_reference', p_provider_reference, 'reservation_id', v_reservation.id
    )
  );

  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE);
  PERFORM set_config('microfams.group_treasury_engine', COALESCE(v_previous_treasury, ''), TRUE);
  RETURN v_payout;
END;
$$;

-- ---------------------------------------------------------------------------
-- 14. Confirmed provider failure or timeout: release and post nothing.
--
-- Money never left the ledger, so no journal exists to reverse. Release the
-- reservation exactly once — funds return to available and the budget commitment
-- is removed — and move the disbursement to 'failed'. Idempotent: a retried
-- failure callback on an already-terminal payout returns it unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fail_group_treasury_payout(
  p_payout_id UUID,
  p_failure_code TEXT,
  p_failure_reason TEXT
) RETURNS payouts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_disbursement group_treasury_disbursements;
  v_reservation group_treasury_reservations;
  v_released BOOLEAN := FALSE;
  v_previous_payout TEXT;
  v_previous_treasury TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'group_treasury' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_NOT_FOUND';
  END IF;
  IF v_payout.state IN ('failed', 'cancelled') THEN RETURN v_payout; END IF;
  IF NOT payout_transition_allowed(v_payout.state, 'failed') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_TRANSITION_INVALID';
  END IF;

  SELECT * INTO v_disbursement FROM group_treasury_disbursements
  WHERE id = v_payout.group_treasury_disbursement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_DISBURSEMENT_NOT_FOUND'; END IF;
  SELECT * INTO v_reservation FROM group_treasury_reservations
  WHERE disbursement_id = v_disbursement.id FOR UPDATE;

  v_previous_payout := current_setting('microfams.payout_engine', TRUE);
  v_previous_treasury := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.payout_engine', 'on', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  UPDATE payouts
  SET state = 'failed', failure_code = left(p_failure_code, 80),
    failure_reason = left(p_failure_reason, 500), terminal_at = NOW(), updated_at = NOW()
  WHERE id = v_payout.id RETURNING * INTO v_payout;

  IF v_reservation.id IS NOT NULL AND v_reservation.state = 'active' THEN
    UPDATE group_treasury_reservations
    SET state = 'released', release_reason_code = 'PROVIDER_PAYOUT_FAILED',
      released_at = NOW(), updated_at = NOW()
    WHERE id = v_reservation.id;
    UPDATE group_treasury_budgets
    SET committed_minor = committed_minor - v_reservation.amount_minor,
      updated_at = NOW()
    WHERE id = v_disbursement.budget_id;
    v_released := TRUE;
  END IF;

  IF v_disbursement.state = 'disbursing' THEN
    UPDATE group_treasury_disbursements
    SET state = 'failed', settled_state_at = NOW(), updated_at = NOW()
    WHERE id = v_disbursement.id;
  END IF;

  IF v_released THEN
    INSERT INTO group_treasury_events(
      organization_id, group_id, budget_id, disbursement_id, event_type,
      from_state, to_state, amount_minor, reason_code, actor_id, correlation_id
    ) VALUES (
      v_payout.organization_id, v_disbursement.group_id, v_disbursement.budget_id,
      v_disbursement.id, 'reservation.released', 'disbursing', 'failed',
      v_reservation.amount_minor, 'PROVIDER_PAYOUT_FAILED', v_payout.actor_id,
      v_disbursement.correlation_id
    );
  END IF;
  INSERT INTO group_treasury_events(
    organization_id, group_id, budget_id, disbursement_id, event_type,
    from_state, to_state, amount_minor, reason_code, actor_id, correlation_id, detail
  ) VALUES (
    v_payout.organization_id, v_disbursement.group_id, v_disbursement.budget_id,
    v_disbursement.id, 'disbursement.failed', 'disbursing', 'failed',
    v_disbursement.amount_minor, 'PROVIDER_PAYOUT_FAILED', v_payout.actor_id,
    v_disbursement.correlation_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'failure_code', left(p_failure_code, 80),
      'reservation_released', v_released
    )
  );

  PERFORM set_config('microfams.payout_engine', COALESCE(v_previous_payout, ''), TRUE);
  PERFORM set_config('microfams.group_treasury_engine', COALESCE(v_previous_treasury, ''), TRUE);
  RETURN v_payout;
END;
$$;

-- ---------------------------------------------------------------------------
-- 15. Late provider success after a terminal payout.
--
-- The reconciliation safety net. A provider that reports success after the
-- payout was failed or cancelled is recorded as an exception, never repaid: the
-- reservation was already released, and repaying automatically would debit the
-- treasury twice. Idempotent on (payout_id, provider_reference).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_group_treasury_late_payout_success(
  p_payout_id UUID,
  p_organization_id UUID,
  p_provider_reference TEXT,
  p_amount_minor BIGINT,
  p_currency TEXT,
  p_beneficiary_fingerprint TEXT,
  p_provider_name TEXT,
  p_provider_environment TEXT,
  p_evidence_snapshot JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_payout payouts;
  v_existing group_treasury_late_payout_exceptions;
  v_result group_treasury_late_payout_exceptions;
  v_previous TEXT;
BEGIN
  SELECT * INTO v_payout FROM payouts
  WHERE id = p_payout_id AND organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_payout.source_type <> 'group_treasury' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_NOT_FOUND';
  END IF;
  IF v_payout.state NOT IN ('failed', 'cancelled') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_LATE_SUCCESS_NOT_APPLICABLE';
  END IF;
  IF p_provider_reference IS NULL
    OR length(p_provider_reference) NOT BETWEEN 1 AND 160
    OR p_amount_minor <> v_payout.amount_minor
    OR upper(p_currency) <> v_payout.currency
    OR lower(p_beneficiary_fingerprint) <> v_payout.beneficiary_fingerprint
    OR p_provider_name <> v_payout.provider_name
    OR p_provider_environment <> v_payout.provider_environment
    OR jsonb_typeof(p_evidence_snapshot) <> 'object' THEN
    RAISE EXCEPTION 'GROUP_TREASURY_PAYOUT_PROVIDER_MISMATCH';
  END IF;

  SELECT * INTO v_existing FROM group_treasury_late_payout_exceptions
  WHERE payout_id = p_payout_id AND provider_reference = p_provider_reference;
  IF FOUND THEN RETURN to_jsonb(v_existing); END IF;

  v_previous := current_setting('microfams.group_treasury_engine', TRUE);
  PERFORM set_config('microfams.group_treasury_engine', 'on', TRUE);

  INSERT INTO group_treasury_late_payout_exceptions(
    organization_id, disbursement_id, payout_id, provider_reference, amount_minor,
    currency, beneficiary_fingerprint, evidence_snapshot
  ) VALUES (
    p_organization_id, v_payout.group_treasury_disbursement_id, p_payout_id,
    p_provider_reference, p_amount_minor, upper(p_currency),
    lower(p_beneficiary_fingerprint),
    p_evidence_snapshot || jsonb_build_object('recorded_without_repaying', TRUE)
  ) RETURNING * INTO v_result;

  PERFORM set_config(
    'microfams.group_treasury_engine', COALESCE(v_previous, ''), TRUE
  );
  RETURN to_jsonb(v_result);
END;
$$;

-- ---------------------------------------------------------------------------
-- 16. Tenant isolation and least privilege.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'group_treasury_beneficiaries', 'group_treasury_late_payout_exceptions'
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

REVOKE ALL ON FUNCTION group_treasury_external_clearing_account_id(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION register_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, TEXT, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION reject_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_group_treasury_external_disbursement(
  UUID, UUID, UUID, UUID, UUID, BIGINT, VARCHAR, TEXT, TEXT, TIMESTAMPTZ,
  TIMESTAMPTZ, UUID, TEXT, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION begin_group_treasury_external_disbursement(
  UUID, UUID, UUID, TEXT, TEXT, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION succeed_group_treasury_payout(
  UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT
) FROM PUBLIC;
REVOKE ALL ON FUNCTION fail_group_treasury_payout(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_group_treasury_late_payout_success(
  UUID, UUID, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION group_treasury_external_clearing_account_id(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION register_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION approve_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION reject_group_treasury_beneficiary(
  UUID, UUID, UUID, UUID, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION request_group_treasury_external_disbursement(
  UUID, UUID, UUID, UUID, UUID, BIGINT, VARCHAR, TEXT, TEXT, TIMESTAMPTZ,
  TIMESTAMPTZ, UUID, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION begin_group_treasury_external_disbursement(
  UUID, UUID, UUID, TEXT, TEXT, UUID
) TO service_role;
GRANT EXECUTE ON FUNCTION succeed_group_treasury_payout(
  UUID, TEXT, TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION fail_group_treasury_payout(UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION record_group_treasury_late_payout_success(
  UUID, UUID, TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB
) TO service_role;
