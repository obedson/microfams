-- GT-06B2: disabled-by-default emergency treasury expenditure and ratification.
SET search_path = public, extensions;

ALTER TABLE group_treasury_reservations ADD COLUMN IF NOT EXISTS emergency_id UUID;
ALTER TABLE group_treasury_reservations ALTER COLUMN disbursement_id DROP NOT NULL;
ALTER TABLE group_treasury_reservations DROP CONSTRAINT IF EXISTS group_treasury_reservations_source_check;
ALTER TABLE group_treasury_reservations ADD CONSTRAINT group_treasury_reservations_source_check
  CHECK ((disbursement_id IS NULL) <> (emergency_id IS NULL));

CREATE TABLE IF NOT EXISTS group_treasury_emergency_policies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  cap_minor BIGINT NOT NULL CHECK (cap_minor > 0 AND cap_minor <= 100000000000),
  minimum_approvers INTEGER NOT NULL DEFAULT 2 CHECK (minimum_approvers BETWEEN 2 AND 10),
  ratification_hours INTEGER NOT NULL DEFAULT 72 CHECK (ratification_hours BETWEEN 1 AND 720),
  notice_deadline_minutes INTEGER NOT NULL DEFAULT 60 CHECK (notice_deadline_minutes BETWEEN 1 AND 10080),
  updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, group_id)
);

CREATE TABLE IF NOT EXISTS group_treasury_emergency_expenditures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  budget_id UUID NOT NULL REFERENCES group_treasury_budgets(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  beneficiary_kind TEXT NOT NULL CHECK (beneficiary_kind IN ('member','group','project')),
  beneficiary_member_id UUID REFERENCES group_members(id) ON DELETE RESTRICT,
  beneficiary_user_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  beneficiary_group_id UUID REFERENCES groups(id) ON DELETE RESTRICT,
  beneficiary_project_id UUID,
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0 AND amount_minor <= 100000000000),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  purpose TEXT NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 8 AND 2000),
  emergency_reason TEXT NOT NULL CHECK (char_length(btrim(emergency_reason)) BETWEEN 10 AND 2000),
  evidence_uri TEXT NOT NULL CHECK (char_length(btrim(evidence_uri)) BETWEEN 3 AND 500),
  state TEXT NOT NULL DEFAULT 'requested' CHECK (state IN (
    'requested','ratification_pending','ratified','ratification_rejected','expired'
  )),
  requested_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  first_approver_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  second_approver_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  reservation_id UUID REFERENCES group_treasury_reservations(id) ON DELETE RESTRICT,
  execution_journal_entry_id UUID REFERENCES journal_entries(id) ON DELETE RESTRICT,
  ratification_proposal_id UUID UNIQUE REFERENCES group_proposals(id) ON DELETE RESTRICT,
  ratification_due_at TIMESTAMPTZ,
  notice_enqueued_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  correlation_id UUID NOT NULL,
  approved_at TIMESTAMPTZ,
  ratified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, idempotency_key),
  CHECK (
    (beneficiary_kind='member' AND beneficiary_member_id IS NOT NULL
      AND beneficiary_user_id IS NOT NULL AND beneficiary_group_id IS NULL
      AND beneficiary_project_id IS NULL)
    OR (beneficiary_kind='group' AND beneficiary_group_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_project_id IS NULL)
    OR (beneficiary_kind='project' AND beneficiary_project_id IS NOT NULL
      AND beneficiary_member_id IS NULL AND beneficiary_user_id IS NULL
      AND beneficiary_group_id IS NULL)
  ),
  CHECK (beneficiary_user_id IS NULL OR requested_by <> beneficiary_user_id),
  CHECK (first_approver_id IS NULL OR first_approver_id <> requested_by),
  CHECK (second_approver_id IS NULL OR second_approver_id <> requested_by),
  CHECK (second_approver_id IS NULL OR second_approver_id <> first_approver_id),
  CHECK ((state='requested') = (approved_at IS NULL)),
  CHECK ((state IN ('ratification_pending','ratified','ratification_rejected')) =
    (execution_journal_entry_id IS NOT NULL AND ratification_proposal_id IS NOT NULL)),
  CHECK ((state='ratified') = (ratified_at IS NOT NULL))
);

ALTER TABLE group_treasury_reservations DROP CONSTRAINT IF EXISTS group_treasury_reservations_emergency_fk;
ALTER TABLE group_treasury_reservations
  ADD CONSTRAINT group_treasury_reservations_emergency_fk
  FOREIGN KEY (emergency_id) REFERENCES group_treasury_emergency_expenditures(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_treasury_emergency_reservation
  ON group_treasury_reservations(emergency_id) WHERE emergency_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_group_treasury_emergency_state
  ON group_treasury_emergency_expenditures(organization_id,group_id,state,created_at DESC);

CREATE OR REPLACE FUNCTION protect_group_treasury_emergency_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.group_treasury_emergency_engine',TRUE)='on' THEN
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_ENGINE_REQUIRED';
END $$;
DROP TRIGGER IF EXISTS group_treasury_emergency_policy_engine ON group_treasury_emergency_policies;
CREATE TRIGGER group_treasury_emergency_policy_engine BEFORE INSERT OR UPDATE OR DELETE
  ON group_treasury_emergency_policies FOR EACH ROW
  EXECUTE FUNCTION protect_group_treasury_emergency_evidence();
DROP TRIGGER IF EXISTS group_treasury_emergency_expenditure_engine ON group_treasury_emergency_expenditures;
CREATE TRIGGER group_treasury_emergency_expenditure_engine BEFORE INSERT OR UPDATE OR DELETE
  ON group_treasury_emergency_expenditures FOR EACH ROW
  EXECUTE FUNCTION protect_group_treasury_emergency_evidence();

CREATE OR REPLACE FUNCTION configure_group_treasury_emergency_policy(
  p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_enabled BOOLEAN,
  p_cap_minor BIGINT,p_ratification_hours INTEGER,p_notice_deadline_minutes INTEGER,
  p_correlation_id UUID
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c UUID; i UUID; old TEXT;
BEGIN
  PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
  SELECT current_constitution_id INTO c FROM groups
  WHERE id=p_group_id AND organization_id=p_organization_id AND lifecycle_state='active';
  IF c IS NULL THEN RAISE EXCEPTION 'GROUP_TREASURY_GROUP_NOT_ACTIVE'; END IF;
  IF p_cap_minor<=0 OR p_ratification_hours NOT BETWEEN 1 AND 720
    OR p_notice_deadline_minutes NOT BETWEEN 1 AND 10080 THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_POLICY_INVALID';
  END IF;
  old:=current_setting('microfams.group_treasury_emergency_engine',TRUE);
  PERFORM set_config('microfams.group_treasury_emergency_engine','on',TRUE);
  INSERT INTO group_treasury_emergency_policies(
    organization_id,group_id,constitution_id,enabled,cap_minor,
    ratification_hours,notice_deadline_minutes,updated_by
  ) VALUES (
    p_organization_id,p_group_id,c,p_enabled,p_cap_minor,
    p_ratification_hours,p_notice_deadline_minutes,p_actor_id
  ) ON CONFLICT(organization_id,group_id) DO UPDATE SET
    constitution_id=EXCLUDED.constitution_id,enabled=EXCLUDED.enabled,
    cap_minor=EXCLUDED.cap_minor,ratification_hours=EXCLUDED.ratification_hours,
    notice_deadline_minutes=EXCLUDED.notice_deadline_minutes,
    updated_by=EXCLUDED.updated_by,updated_at=NOW()
  RETURNING id INTO i;
  PERFORM set_config('microfams.group_treasury_emergency_engine',COALESCE(old,''),TRUE);
  RETURN i;
END $$;

CREATE OR REPLACE FUNCTION request_group_treasury_emergency(
  p_organization_id UUID,p_group_id UUID,p_budget_id UUID,p_beneficiary_kind TEXT,
  p_beneficiary_member_id UUID,p_beneficiary_group_id UUID,p_beneficiary_project_id UUID,
  p_amount_minor BIGINT,p_currency VARCHAR(3),p_purpose TEXT,p_emergency_reason TEXT,
  p_evidence_uri TEXT,p_requested_by UUID,p_idempotency_key TEXT,p_correlation_id UUID
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE pol group_treasury_emergency_policies; b group_treasury_budgets;
  c UUID; u UUID; i UUID; old TEXT;
BEGIN
  SELECT id INTO i FROM group_treasury_emergency_expenditures
  WHERE organization_id=p_organization_id AND idempotency_key=p_idempotency_key;
  IF i IS NOT NULL THEN RETURN i; END IF;
  SELECT * INTO pol FROM group_treasury_emergency_policies
  WHERE organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;
  IF NOT FOUND OR NOT pol.enabled THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_DISABLED'; END IF;
  SELECT * INTO b FROM group_treasury_budgets
  WHERE id=p_budget_id AND organization_id=p_organization_id AND group_id=p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_FOUND'; END IF;
  IF b.state<>'active' THEN RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_NOT_ACTIVE'; END IF;
  IF b.currency<>p_currency THEN RAISE EXCEPTION 'GROUP_TREASURY_CURRENCY_MISMATCH'; END IF;
  IF p_amount_minor>pol.cap_minor THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_CAP_EXCEEDED'; END IF;
  IF length(btrim(COALESCE(p_emergency_reason,''))) NOT BETWEEN 10 AND 2000
    OR length(btrim(COALESCE(p_evidence_uri,''))) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_EVIDENCE_REQUIRED';
  END IF;
  SELECT current_constitution_id INTO c FROM groups
  WHERE id=p_group_id AND organization_id=p_organization_id AND lifecycle_state='active';
  IF c IS NULL OR c IS DISTINCT FROM b.constitution_id
    OR c IS DISTINCT FROM pol.constitution_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CONSTITUTION_CHANGED';
  END IF;
  IF p_beneficiary_kind='member' THEN
    SELECT user_id INTO u FROM group_members
    WHERE id=p_beneficiary_member_id AND organization_id=p_organization_id
      AND group_id=p_group_id AND status='active';
    IF u IS NULL THEN RAISE EXCEPTION 'GROUP_TREASURY_BENEFICIARY_NOT_MEMBER'; END IF;
    IF u=p_requested_by THEN RAISE EXCEPTION 'GROUP_TREASURY_SELF_BENEFICIARY_FORBIDDEN'; END IF;
  END IF;
  old:=current_setting('microfams.group_treasury_emergency_engine',TRUE);
  PERFORM set_config('microfams.group_treasury_emergency_engine','on',TRUE);
  INSERT INTO group_treasury_emergency_expenditures(
    organization_id,group_id,budget_id,constitution_id,beneficiary_kind,
    beneficiary_member_id,beneficiary_user_id,beneficiary_group_id,beneficiary_project_id,
    amount_minor,currency,purpose,emergency_reason,evidence_uri,requested_by,
    idempotency_key,correlation_id
  ) VALUES (
    p_organization_id,p_group_id,p_budget_id,c,p_beneficiary_kind,
    p_beneficiary_member_id,u,p_beneficiary_group_id,p_beneficiary_project_id,
    p_amount_minor,p_currency,btrim(p_purpose),btrim(p_emergency_reason),
    btrim(p_evidence_uri),p_requested_by,p_idempotency_key,p_correlation_id
  ) RETURNING id INTO i;
  PERFORM set_config('microfams.group_treasury_emergency_engine',COALESCE(old,''),TRUE);
  RETURN i;
END $$;

CREATE OR REPLACE FUNCTION approve_group_treasury_emergency(
  p_organization_id UUID,p_emergency_id UUID,p_actor_id UUID,p_correlation_id UUID
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e group_treasury_emergency_expenditures; pol group_treasury_emergency_policies;
  avail BIGINT; src UUID; credit UUID; journal UUID; reservation UUID;
  proposal UUID; due TIMESTAMPTZ; old TEXT; key TEXT; member UUID;
BEGIN
  SELECT * INTO e FROM group_treasury_emergency_expenditures
  WHERE id=p_emergency_id AND organization_id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_NOT_FOUND'; END IF;
  IF e.state<>'requested' THEN RETURN e.execution_journal_entry_id; END IF;
  IF p_actor_id=e.requested_by THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_SELF_APPROVAL'; END IF;
  IF NOT group_treasury_checker_permitted(p_organization_id,e.group_id,p_actor_id) THEN
    RAISE EXCEPTION 'GROUP_TREASURY_CHECKER_NOT_PERMITTED';
  END IF;
  old:=current_setting('microfams.group_treasury_emergency_engine',TRUE);
  PERFORM set_config('microfams.group_treasury_emergency_engine','on',TRUE);
  IF e.first_approver_id IS NULL THEN
    UPDATE group_treasury_emergency_expenditures
    SET first_approver_id=p_actor_id,updated_at=NOW() WHERE id=e.id;
    PERFORM set_config('microfams.group_treasury_emergency_engine',COALESCE(old,''),TRUE);
    RETURN NULL;
  END IF;
  IF p_actor_id=e.first_approver_id THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_APPROVER_DUPLICATE';
  END IF;
  SELECT * INTO pol FROM group_treasury_emergency_policies
  WHERE organization_id=p_organization_id AND group_id=e.group_id FOR UPDATE;
  IF NOT pol.enabled OR e.amount_minor>pol.cap_minor THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_DISABLED'; END IF;
  IF e.constitution_id IS DISTINCT FROM pol.constitution_id THEN RAISE EXCEPTION 'GROUP_TREASURY_CONSTITUTION_CHANGED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM group_treasury_budgets WHERE id=e.budget_id AND state='active' AND committed_minor+disbursed_minor+e.amount_minor<=ceiling_minor) THEN RAISE EXCEPTION 'GROUP_TREASURY_BUDGET_CEILING_EXCEEDED'; END IF;
  avail:=group_treasury_available_minor(p_organization_id,e.group_id);
  IF avail<e.amount_minor THEN RAISE EXCEPTION 'GROUP_TREASURY_INSUFFICIENT_AVAILABLE_FUNDS'; END IF;
  src:=group_treasury_account_id(p_organization_id,e.group_id);
  key:=upper(substr(md5(e.group_id::TEXT),1,16));
  credit:=ensure_wallet_system_account(
    p_organization_id,'GROUP.'||key||'.EMERGENCY_PAYABLE',
    'Group emergency expenditure payable','liability','credit'
  );
  journal:=post_wallet_journal(
    p_organization_id,'group.treasury.emergency',e.id::TEXT,
    'Execute emergency group treasury expenditure',
    jsonb_build_array(
      jsonb_build_object('account_id',src,'line_number',1,'side','debit',
        'amount_minor',e.amount_minor,'memo','Emergency treasury expenditure'),
      jsonb_build_object('account_id',credit,'line_number',2,'side','credit',
        'amount_minor',e.amount_minor,'memo','Emergency treasury payable')
    )
  );
  PERFORM set_config('microfams.group_treasury_engine','on',TRUE);
  INSERT INTO group_treasury_reservations(
    organization_id,group_id,budget_id,disbursement_id,emergency_id,source_account_id,
    amount_minor,currency,state,available_minor_at_reserve,expires_at,
    consumed_journal_entry_id,reserved_by,consumed_at,correlation_id
  ) VALUES (
    p_organization_id,e.group_id,e.budget_id,NULL,e.id,src,e.amount_minor,e.currency,
    'consumed',avail,NOW(),journal,p_actor_id,NOW(),p_correlation_id
  ) RETURNING id INTO reservation;
  due:=NOW()+make_interval(hours=>pol.ratification_hours);
  proposal:=create_group_proposal(
    p_organization_id,e.group_id,p_actor_id,'treasury_disbursement',
    'Emergency treasury expenditure ratification',jsonb_build_array(e.evidence_uri),
    jsonb_build_object('action','emergency_ratification','emergency_id',e.id,
      'amount_minor',e.amount_minor,'currency',e.currency),
    ARRAY[]::UUID[],NOW(),due,p_correlation_id,NOW()
  );
  UPDATE group_treasury_emergency_expenditures SET
    state='ratification_pending',second_approver_id=p_actor_id,approved_at=NOW(),
    reservation_id=reservation,execution_journal_entry_id=journal,
    ratification_proposal_id=proposal,ratification_due_at=due,
    notice_enqueued_at=NOW(),updated_at=NOW()
  WHERE id=e.id;
  UPDATE group_treasury_budgets
  SET disbursed_minor=disbursed_minor+e.amount_minor,updated_at=NOW()
  WHERE id=e.budget_id;
  FOR member IN
    SELECT user_id FROM group_members
    WHERE organization_id=p_organization_id AND group_id=e.group_id
      AND status='active' AND is_active
  LOOP
    INSERT INTO notifications(
      user_id,organization_id,source_type,source_id,title,message,type
    ) VALUES (
      member,p_organization_id,'group_treasury_emergency',e.id,
      'Emergency treasury expenditure',
      'An emergency treasury expenditure requires member ratification.',
      'group_treasury'
    ) ON CONFLICT(user_id,source_type,source_id) DO NOTHING;
  END LOOP;
  PERFORM set_config('microfams.group_treasury_engine','',TRUE);
  PERFORM set_config('microfams.group_treasury_emergency_engine',COALESCE(old,''),TRUE);
  RETURN journal;
END $$;

CREATE OR REPLACE FUNCTION ratify_group_treasury_emergency(
  p_organization_id UUID,p_emergency_id UUID,p_actor_id UUID,p_correlation_id UUID
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e group_treasury_emergency_expenditures; p group_proposals; target TEXT; old TEXT;
BEGIN
  SELECT * INTO e FROM group_treasury_emergency_expenditures
  WHERE id=p_emergency_id AND organization_id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_NOT_FOUND'; END IF;
  IF e.state NOT IN('ratification_pending','ratified','ratification_rejected') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_EMERGENCY_NOT_PENDING_RATIFICATION';
  END IF;
  SELECT * INTO p FROM group_proposals
  WHERE id=e.ratification_proposal_id AND organization_id=p_organization_id;
  IF p.state NOT IN('approved','rejected','expired') THEN
    RAISE EXCEPTION 'GROUP_TREASURY_RATIFICATION_NOT_DECIDED';
  END IF;
  target:=CASE WHEN p.state='approved' THEN 'ratified' ELSE 'ratification_rejected' END;
  IF e.state=target THEN RETURN target; END IF;
  old:=current_setting('microfams.group_treasury_emergency_engine',TRUE);
  PERFORM set_config('microfams.group_treasury_emergency_engine','on',TRUE);
  UPDATE group_treasury_emergency_expenditures SET
    state=target,ratified_at=CASE WHEN target='ratified' THEN NOW() ELSE NULL END,
    updated_at=NOW()
  WHERE id=e.id;
  PERFORM set_config('microfams.group_treasury_emergency_engine',COALESCE(old,''),TRUE);
  RETURN target;
END $$;

DO $$ DECLARE t TEXT; BEGIN
  FOREACH t IN ARRAY ARRAY[
    'group_treasury_emergency_policies','group_treasury_emergency_expenditures'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read ON %I',t);
    EXECUTE format(
      'CREATE POLICY tenant_read ON %I FOR SELECT USING(has_active_organization_membership(organization_id))',t
    );
    EXECUTE format('REVOKE ALL ON %I FROM PUBLIC,anon,authenticated',t);
    EXECUTE format('GRANT SELECT ON %I TO service_role',t);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION configure_group_treasury_emergency_policy(UUID,UUID,UUID,BOOLEAN,BIGINT,INTEGER,INTEGER,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION request_group_treasury_emergency(UUID,UUID,UUID,TEXT,UUID,UUID,UUID,BIGINT,VARCHAR,TEXT,TEXT,TEXT,UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION approve_group_treasury_emergency(UUID,UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION ratify_group_treasury_emergency(UUID,UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION configure_group_treasury_emergency_policy(UUID,UUID,UUID,BOOLEAN,BIGINT,INTEGER,INTEGER,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION request_group_treasury_emergency(UUID,UUID,UUID,TEXT,UUID,UUID,UUID,BIGINT,VARCHAR,TEXT,TEXT,TEXT,UUID,TEXT,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION approve_group_treasury_emergency(UUID,UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION ratify_group_treasury_emergency(UUID,UUID,UUID,UUID) TO service_role;
