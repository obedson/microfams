-- Trust review, appeals, suspension lifecycle, and non-destructive retention controls.
BEGIN;

CREATE TABLE trust_review_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  subject_type TEXT NOT NULL CHECK (subject_type IN ('user', 'organization', 'membership', 'transaction', 'content', 'other')),
  subject_id UUID NOT NULL,
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'assigned', 'decided', 'appealed', 'closed')),
  opened_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_reviewer_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  assigned_at TIMESTAMPTZ,
  decided_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  UNIQUE(opened_by, idempotency_key),
  CHECK ((status = 'open' AND assigned_reviewer_id IS NULL AND assigned_at IS NULL)
    OR (status <> 'open' AND assigned_reviewer_id IS NOT NULL AND assigned_at IS NOT NULL)),
  CHECK (decided_at IS NULL OR assigned_at IS NOT NULL),
  CHECK (closed_at IS NULL OR decided_at IS NOT NULL)
);
CREATE INDEX idx_trust_review_cases_org_status ON trust_review_cases(organization_id, status, opened_at DESC);
CREATE INDEX idx_trust_review_cases_reviewer ON trust_review_cases(assigned_reviewer_id, status, priority);

CREATE TABLE trust_review_case_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'opened', 'assigned', 'conflict_declared', 'decision_recorded',
    'appeal_filed', 'appeal_decided', 'closed'
  )),
  reason_code TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(payload) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_trust_review_case_events_case ON trust_review_case_events(case_id, occurred_at);

CREATE TABLE trust_reviewer_conflicts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  reviewer_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  declared_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  conflict_type TEXT NOT NULL CHECK (conflict_type IN ('self', 'relationship', 'financial_interest', 'prior_involvement', 'other')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 1000),
  declared_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(case_id, reviewer_id)
);

CREATE TABLE trust_review_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL UNIQUE REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  reviewer_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  outcome TEXT NOT NULL CHECK (outcome IN ('no_action', 'warning', 'suspend_membership', 'suspend_organization', 'suspend_user', 'refer')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  rationale TEXT NOT NULL CHECK (char_length(trim(rationale)) BETWEEN 10 AND 4000),
  decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE trust_appeals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  decision_id UUID NOT NULL REFERENCES trust_review_decisions(id) ON DELETE RESTRICT,
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  appellant_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  grounds TEXT NOT NULL CHECK (char_length(trim(grounds)) BETWEEN 10 AND 4000),
  status TEXT NOT NULL DEFAULT 'filed' CHECK (status IN ('filed', 'assigned', 'upheld', 'modified', 'overturned', 'dismissed')),
  assigned_reviewer_id UUID REFERENCES users(id) ON DELETE RESTRICT,
  filed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  assigned_at TIMESTAMPTZ,
  decided_at TIMESTAMPTZ,
  outcome_reason_code TEXT,
  outcome_rationale TEXT CHECK (outcome_rationale IS NULL OR char_length(trim(outcome_rationale)) BETWEEN 10 AND 4000),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  UNIQUE(appellant_id, idempotency_key),
  UNIQUE(case_id, appellant_id),
  CHECK ((status = 'filed' AND assigned_reviewer_id IS NULL AND assigned_at IS NULL)
    OR (status <> 'filed' AND assigned_reviewer_id IS NOT NULL AND assigned_at IS NOT NULL)),
  CHECK ((status IN ('filed', 'assigned') AND decided_at IS NULL AND outcome_reason_code IS NULL)
    OR (status IN ('upheld', 'modified', 'overturned', 'dismissed') AND decided_at IS NOT NULL
      AND outcome_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$' AND outcome_rationale IS NOT NULL))
);
CREATE INDEX idx_trust_appeals_case ON trust_appeals(case_id, filed_at DESC);

CREATE TABLE trust_appeal_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  appeal_id UUID NOT NULL REFERENCES trust_appeals(id) ON DELETE RESTRICT,
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type IN ('filed', 'assigned', 'decided')),
  payload JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(payload) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE organization_suspensions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  decision_id UUID REFERENCES trust_review_decisions(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'lifted')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  suspended_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  suspended_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lifted_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  lifted_at TIMESTAMPTZ,
  lift_reason_code TEXT,
  CHECK ((status = 'active' AND lifted_by IS NULL AND lifted_at IS NULL AND lift_reason_code IS NULL)
    OR (status = 'lifted' AND lifted_by IS NOT NULL AND lifted_at IS NOT NULL
      AND lift_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'))
);
CREATE UNIQUE INDEX uq_active_organization_suspension ON organization_suspensions(organization_id) WHERE status = 'active';

CREATE TABLE organization_membership_suspensions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  membership_id UUID NOT NULL REFERENCES organization_memberships(id) ON DELETE RESTRICT,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  case_id UUID NOT NULL REFERENCES trust_review_cases(id) ON DELETE RESTRICT,
  decision_id UUID REFERENCES trust_review_decisions(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'lifted')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  suspended_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  suspended_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lifted_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  lifted_at TIMESTAMPTZ,
  lift_reason_code TEXT,
  CHECK ((status = 'active' AND lifted_by IS NULL AND lifted_at IS NULL AND lift_reason_code IS NULL)
    OR (status = 'lifted' AND lifted_by IS NOT NULL AND lifted_at IS NOT NULL
      AND lift_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'))
);
CREATE UNIQUE INDEX uq_active_membership_suspension ON organization_membership_suspensions(membership_id) WHERE status = 'active';

CREATE TABLE data_retention_policies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  data_class TEXT NOT NULL CHECK (data_class ~ '^[a-z][a-z0-9_.]{2,63}$'),
  retention_days INTEGER NOT NULL CHECK (retention_days BETWEEN 1 AND 36500),
  disposition TEXT NOT NULL DEFAULT 'review' CHECK (disposition IN ('review', 'anonymize', 'delete')),
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  destructive_enabled BOOLEAN NOT NULL DEFAULT FALSE CHECK (destructive_enabled = FALSE),
  policy_version INTEGER NOT NULL DEFAULT 1 CHECK (policy_version > 0),
  created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE NULLS NOT DISTINCT (organization_id, data_class, policy_version)
);

CREATE TABLE data_legal_holds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  subject_type TEXT NOT NULL CHECK (subject_type IN ('user', 'organization', 'membership', 'case', 'data_class')),
  subject_id TEXT NOT NULL,
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released')),
  placed_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  placed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  released_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  released_at TIMESTAMPTZ,
  release_reason_code TEXT,
  CHECK ((status = 'active' AND released_by IS NULL AND released_at IS NULL AND release_reason_code IS NULL)
    OR (status = 'released' AND released_by IS NOT NULL AND released_at IS NOT NULL
      AND release_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'))
);
CREATE INDEX idx_data_legal_holds_active ON data_legal_holds(organization_id, subject_type, subject_id) WHERE status = 'active';

CREATE TABLE data_retention_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  policy_id UUID NOT NULL REFERENCES data_retention_policies(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL DEFAULT 'dry_run' CHECK (mode = 'dry_run'),
  status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'completed', 'failed')),
  requested_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  summary JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(summary) = 'object'),
  UNIQUE(requested_by, idempotency_key)
);

CREATE TABLE data_retention_run_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id UUID NOT NULL REFERENCES data_retention_runs(id) ON DELETE RESTRICT,
  organization_id UUID REFERENCES organizations(id) ON DELETE RESTRICT,
  resource_type TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  proposed_action TEXT NOT NULL CHECK (proposed_action IN ('retain', 'would_anonymize', 'would_delete', 'held', 'excluded')),
  reason_code TEXT NOT NULL,
  executed BOOLEAN NOT NULL DEFAULT FALSE CHECK (executed = FALSE),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(run_id, resource_type, resource_id)
);

CREATE TABLE trust_idempotency_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  operation TEXT NOT NULL,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  result JSONB NOT NULL CHECK (jsonb_typeof(result) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(actor_id, operation, idempotency_key)
);

CREATE OR REPLACE FUNCTION protect_trust_append_only() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'Trust and retention evidence is append-only'; END;
$$;
CREATE TRIGGER trust_case_events_append_only BEFORE UPDATE OR DELETE ON trust_review_case_events FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE TRIGGER trust_decisions_append_only BEFORE UPDATE OR DELETE ON trust_review_decisions FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE TRIGGER trust_conflicts_append_only BEFORE UPDATE OR DELETE ON trust_reviewer_conflicts FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE TRIGGER trust_appeal_events_append_only BEFORE UPDATE OR DELETE ON trust_appeal_events FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE TRIGGER retention_run_items_append_only BEFORE UPDATE OR DELETE ON data_retention_run_items FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE TRIGGER trust_idempotency_append_only BEFORE UPDATE OR DELETE ON trust_idempotency_records FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();

CREATE OR REPLACE FUNCTION trust_require_platform_admin(p_actor UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_active_platform_administrator(p_actor) THEN
    RAISE EXCEPTION 'Active platform administrator authority is required';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trust_existing_result(p_actor UUID, p_operation TEXT, p_key TEXT, p_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_record trust_idempotency_records;
BEGIN
  SELECT * INTO v_record FROM trust_idempotency_records
  WHERE actor_id = p_actor AND operation = p_operation AND idempotency_key = p_key;
  IF v_record.id IS NULL THEN RETURN NULL; END IF;
  IF v_record.request_hash <> p_hash THEN RAISE EXCEPTION 'Idempotency key reused with different facts'; END IF;
  RETURN v_record.result;
END;
$$;

CREATE OR REPLACE FUNCTION trust_store_result(p_actor UUID, p_operation TEXT, p_key TEXT, p_hash TEXT, p_result JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO trust_idempotency_records(actor_id, operation, idempotency_key, request_hash, result)
  VALUES (p_actor, p_operation, p_key, p_hash, p_result);
  RETURN p_result;
END;
$$;

CREATE OR REPLACE FUNCTION open_trust_review_case(
  p_actor UUID, p_organization UUID, p_subject_type TEXT, p_subject_id UUID,
  p_reason_code TEXT, p_priority TEXT, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case trust_review_cases; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT || ':open:' || p_idempotency_key, 0));
  v_result := trust_existing_result(p_actor, 'review.open', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  INSERT INTO trust_review_cases(organization_id, subject_type, subject_id, reason_code, priority, opened_by, idempotency_key, request_hash)
  VALUES (p_organization, p_subject_type, p_subject_id, p_reason_code, p_priority, p_actor, p_idempotency_key, p_request_hash) RETURNING * INTO v_case;
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, reason_code)
  VALUES (v_case.id, p_organization, p_actor, 'opened', p_reason_code);
  v_result := jsonb_build_object('caseId', v_case.id, 'status', v_case.status);
  RETURN trust_store_result(p_actor, 'review.open', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION assign_trust_review_case(
  p_actor UUID, p_case UUID, p_reviewer UUID, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case trust_review_cases; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('review:' || p_case::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'review.assign', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_case FROM trust_review_cases WHERE id = p_case FOR UPDATE;
  IF v_case.id IS NULL OR v_case.status NOT IN ('open', 'assigned') THEN RAISE EXCEPTION 'Review case cannot be assigned'; END IF;
  IF NOT is_active_platform_administrator(p_reviewer) THEN RAISE EXCEPTION 'Reviewer must be an active platform administrator'; END IF;
  IF v_case.subject_type = 'user' AND v_case.subject_id = p_reviewer THEN RAISE EXCEPTION 'Reviewer cannot review themselves'; END IF;
  IF v_case.subject_type = 'membership' AND EXISTS (
    SELECT 1 FROM organization_memberships WHERE id = v_case.subject_id AND user_id = p_reviewer
  ) THEN RAISE EXCEPTION 'Reviewer cannot review their own membership'; END IF;
  IF EXISTS (SELECT 1 FROM trust_reviewer_conflicts WHERE case_id = p_case AND reviewer_id = p_reviewer) THEN
    RAISE EXCEPTION 'Reviewer has a declared conflict';
  END IF;
  UPDATE trust_review_cases SET assigned_reviewer_id = p_reviewer, assigned_at = COALESCE(assigned_at, NOW()), status = 'assigned'
  WHERE id = p_case RETURNING * INTO v_case;
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, payload)
  VALUES (p_case, v_case.organization_id, p_actor, 'assigned', jsonb_build_object('reviewerId', p_reviewer));
  v_result := jsonb_build_object('caseId', p_case, 'status', 'assigned', 'reviewerId', p_reviewer);
  RETURN trust_store_result(p_actor, 'review.assign', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION declare_trust_reviewer_conflict(
  p_actor UUID, p_case UUID, p_conflict_type TEXT, p_note TEXT,
  p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case trust_review_cases; v_conflict UUID; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('review:' || p_case::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'review.conflict', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_case FROM trust_review_cases WHERE id = p_case FOR UPDATE;
  IF v_case.id IS NULL OR v_case.assigned_reviewer_id <> p_actor OR v_case.status <> 'assigned' THEN
    RAISE EXCEPTION 'Only the assigned reviewer can declare this conflict';
  END IF;
  INSERT INTO trust_reviewer_conflicts(case_id, reviewer_id, declared_by, conflict_type, note)
  VALUES (p_case, p_actor, p_actor, p_conflict_type, NULLIF(trim(p_note), '')) RETURNING id INTO v_conflict;
  UPDATE trust_review_cases SET assigned_reviewer_id = NULL, assigned_at = NULL, status = 'open' WHERE id = p_case;
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, payload)
  VALUES (p_case, v_case.organization_id, p_actor, 'conflict_declared', jsonb_build_object('conflictId', v_conflict, 'type', p_conflict_type));
  v_result := jsonb_build_object('caseId', p_case, 'status', 'open', 'conflictId', v_conflict);
  RETURN trust_store_result(p_actor, 'review.conflict', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION decide_trust_review_case(
  p_actor UUID, p_case UUID, p_outcome TEXT, p_reason_code TEXT, p_rationale TEXT,
  p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case trust_review_cases; v_decision UUID; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('review:' || p_case::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'review.decide', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_case FROM trust_review_cases WHERE id = p_case FOR UPDATE;
  IF v_case.id IS NULL OR v_case.status <> 'assigned' OR v_case.assigned_reviewer_id <> p_actor THEN
    RAISE EXCEPTION 'Only the assigned reviewer can decide this case';
  END IF;
  IF EXISTS (SELECT 1 FROM trust_reviewer_conflicts WHERE case_id = p_case AND reviewer_id = p_actor) THEN
    RAISE EXCEPTION 'A conflicted reviewer cannot decide this case';
  END IF;
  INSERT INTO trust_review_decisions(case_id, organization_id, reviewer_id, outcome, reason_code, rationale)
  VALUES (p_case, v_case.organization_id, p_actor, p_outcome, p_reason_code, trim(p_rationale)) RETURNING id INTO v_decision;
  UPDATE trust_review_cases SET status = 'decided', decided_at = NOW() WHERE id = p_case;
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, reason_code, payload)
  VALUES (p_case, v_case.organization_id, p_actor, 'decision_recorded', p_reason_code, jsonb_build_object('decisionId', v_decision, 'outcome', p_outcome));
  v_result := jsonb_build_object('caseId', p_case, 'decisionId', v_decision, 'status', 'decided', 'outcome', p_outcome);
  RETURN trust_store_result(p_actor, 'review.decide', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION file_trust_appeal(
  p_actor UUID, p_case UUID, p_grounds TEXT, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case trust_review_cases; v_decision trust_review_decisions; v_appeal trust_appeals; v_result JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT || ':appeal:' || p_idempotency_key, 0));
  v_result := trust_existing_result(p_actor, 'appeal.file', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_case FROM trust_review_cases WHERE id = p_case FOR UPDATE;
  SELECT * INTO v_decision FROM trust_review_decisions WHERE case_id = p_case;
  IF v_case.id IS NULL OR v_case.status <> 'decided' OR v_decision.id IS NULL THEN RAISE EXCEPTION 'Decided review case not found'; END IF;
  IF NOT (
    (v_case.subject_type = 'user' AND v_case.subject_id = p_actor)
    OR (v_case.subject_type = 'membership' AND EXISTS (SELECT 1 FROM organization_memberships WHERE id = v_case.subject_id AND user_id = p_actor))
    OR (v_case.organization_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM organization_memberships WHERE organization_id = v_case.organization_id AND user_id = p_actor
        AND status = 'active' AND role IN ('owner', 'admin')
    ))
  ) THEN RAISE EXCEPTION 'Appellant is not authorized for this case'; END IF;
  INSERT INTO trust_appeals(case_id, decision_id, organization_id, appellant_id, grounds, idempotency_key, request_hash)
  VALUES (p_case, v_decision.id, v_case.organization_id, p_actor, trim(p_grounds), p_idempotency_key, p_request_hash) RETURNING * INTO v_appeal;
  UPDATE trust_review_cases SET status = 'appealed' WHERE id = p_case;
  INSERT INTO trust_appeal_events(appeal_id, case_id, organization_id, actor_id, event_type)
  VALUES (v_appeal.id, p_case, v_case.organization_id, p_actor, 'filed');
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, payload)
  VALUES (p_case, v_case.organization_id, p_actor, 'appeal_filed', jsonb_build_object('appealId', v_appeal.id));
  v_result := jsonb_build_object('appealId', v_appeal.id, 'caseId', p_case, 'status', 'filed');
  RETURN trust_store_result(p_actor, 'appeal.file', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION decide_trust_appeal(
  p_actor UUID, p_appeal UUID, p_outcome TEXT, p_reason_code TEXT, p_rationale TEXT,
  p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_appeal trust_appeals; v_original UUID; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('appeal:' || p_appeal::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'appeal.decide', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_appeal FROM trust_appeals WHERE id = p_appeal FOR UPDATE;
  SELECT reviewer_id INTO v_original FROM trust_review_decisions WHERE id = v_appeal.decision_id;
  IF v_appeal.id IS NULL OR v_appeal.status NOT IN ('filed', 'assigned') THEN RAISE EXCEPTION 'Appeal cannot be decided'; END IF;
  IF v_original = p_actor OR v_appeal.appellant_id = p_actor THEN RAISE EXCEPTION 'Appeal reviewer must be independent'; END IF;
  UPDATE trust_appeals SET status = p_outcome, assigned_reviewer_id = p_actor,
    assigned_at = COALESCE(assigned_at, NOW()), decided_at = NOW(),
    outcome_reason_code = p_reason_code, outcome_rationale = trim(p_rationale)
  WHERE id = p_appeal RETURNING * INTO v_appeal;
  UPDATE trust_review_cases SET status = 'closed', closed_at = NOW() WHERE id = v_appeal.case_id;
  INSERT INTO trust_appeal_events(appeal_id, case_id, organization_id, actor_id, event_type, payload)
  VALUES (p_appeal, v_appeal.case_id, v_appeal.organization_id, p_actor, 'decided', jsonb_build_object('outcome', p_outcome));
  INSERT INTO trust_review_case_events(case_id, organization_id, actor_id, event_type, reason_code, payload)
  VALUES (v_appeal.case_id, v_appeal.organization_id, p_actor, 'appeal_decided', p_reason_code, jsonb_build_object('appealId', p_appeal, 'outcome', p_outcome));
  v_result := jsonb_build_object('appealId', p_appeal, 'caseId', v_appeal.case_id, 'status', p_outcome);
  RETURN trust_store_result(p_actor, 'appeal.decide', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION suspend_trust_organization(
  p_actor UUID, p_organization UUID, p_case UUID, p_reason_code TEXT,
  p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_decision trust_review_decisions; v_suspension organization_suspensions; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('org-suspension:' || p_organization::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'organization.suspend', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_decision FROM trust_review_decisions WHERE case_id = p_case;
  IF v_decision.id IS NULL OR v_decision.outcome <> 'suspend_organization' OR v_decision.organization_id <> p_organization THEN
    RAISE EXCEPTION 'Matching organization suspension decision is required';
  END IF;
  INSERT INTO organization_suspensions(organization_id, case_id, decision_id, reason_code, suspended_by)
  VALUES (p_organization, p_case, v_decision.id, p_reason_code, p_actor) RETURNING * INTO v_suspension;
  UPDATE organizations SET status = 'suspended', updated_at = NOW() WHERE id = p_organization AND status = 'active';
  v_result := jsonb_build_object('suspensionId', v_suspension.id, 'organizationId', p_organization, 'status', 'active');
  RETURN trust_store_result(p_actor, 'organization.suspend', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION resume_trust_organization(
  p_actor UUID, p_organization UUID, p_reason_code TEXT, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_suspension organization_suspensions; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended('org-suspension:' || p_organization::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'organization.resume', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_suspension FROM organization_suspensions WHERE organization_id = p_organization AND status = 'active' FOR UPDATE;
  IF v_suspension.id IS NULL THEN RAISE EXCEPTION 'Active organization suspension not found'; END IF;
  UPDATE organization_suspensions SET status = 'lifted', lifted_by = p_actor, lifted_at = NOW(), lift_reason_code = p_reason_code WHERE id = v_suspension.id;
  UPDATE organizations SET status = 'active', updated_at = NOW() WHERE id = p_organization AND status = 'suspended';
  v_result := jsonb_build_object('suspensionId', v_suspension.id, 'organizationId', p_organization, 'status', 'lifted');
  RETURN trust_store_result(p_actor, 'organization.resume', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION suspend_trust_membership(
  p_actor UUID, p_membership UUID, p_case UUID, p_reason_code TEXT,
  p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_membership organization_memberships; v_decision trust_review_decisions; v_suspension organization_membership_suspensions; v_result JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('membership-suspension:' || p_membership::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'membership.suspend', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_membership FROM organization_memberships WHERE id = p_membership FOR UPDATE;
  IF v_membership.id IS NULL OR NOT (
    is_active_platform_administrator(p_actor)
    OR EXISTS (
      SELECT 1 FROM organization_memberships actor_membership
      WHERE actor_membership.organization_id = v_membership.organization_id
        AND actor_membership.user_id = p_actor
        AND actor_membership.status = 'active'
        AND actor_membership.role IN ('owner', 'admin')
    )
  ) THEN RAISE EXCEPTION 'Authorized active membership not found'; END IF;
  SELECT * INTO v_decision FROM trust_review_decisions WHERE case_id = p_case;
  IF v_membership.status <> 'active' THEN RAISE EXCEPTION 'Authorized active membership not found'; END IF;
  IF v_decision.id IS NULL OR v_decision.outcome <> 'suspend_membership' OR v_decision.organization_id <> v_membership.organization_id THEN
    RAISE EXCEPTION 'Matching membership suspension decision is required';
  END IF;
  IF v_membership.role = 'owner' AND NOT EXISTS (
    SELECT 1 FROM organization_memberships WHERE organization_id = v_membership.organization_id AND status = 'active'
      AND role = 'owner' AND id <> p_membership
  ) THEN RAISE EXCEPTION 'The last active organization owner cannot be suspended'; END IF;
  INSERT INTO organization_membership_suspensions(membership_id, organization_id, case_id, decision_id, reason_code, suspended_by)
  VALUES (p_membership, v_membership.organization_id, p_case, v_decision.id, p_reason_code, p_actor) RETURNING * INTO v_suspension;
  UPDATE organization_memberships SET status = 'suspended', updated_at = NOW() WHERE id = p_membership;
  v_result := jsonb_build_object('suspensionId', v_suspension.id, 'membershipId', p_membership, 'status', 'active');
  RETURN trust_store_result(p_actor, 'membership.suspend', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION resume_trust_membership(
  p_actor UUID, p_membership UUID, p_reason_code TEXT, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_suspension organization_membership_suspensions; v_result JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('membership-suspension:' || p_membership::TEXT, 0));
  v_result := trust_existing_result(p_actor, 'membership.resume', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_suspension FROM organization_membership_suspensions WHERE membership_id = p_membership AND status = 'active' FOR UPDATE;
  IF v_suspension.id IS NULL OR NOT (
    is_active_platform_administrator(p_actor)
    OR EXISTS (
      SELECT 1 FROM organization_memberships actor_membership
      WHERE actor_membership.organization_id = v_suspension.organization_id
        AND actor_membership.user_id = p_actor
        AND actor_membership.status = 'active'
        AND actor_membership.role IN ('owner', 'admin')
    )
  ) THEN RAISE EXCEPTION 'Authorized active membership suspension not found'; END IF;
  IF EXISTS (SELECT 1 FROM organization_suspensions WHERE organization_id = v_suspension.organization_id AND status = 'active') THEN
    RAISE EXCEPTION 'Membership cannot resume while organization is suspended';
  END IF;
  UPDATE organization_membership_suspensions SET status = 'lifted', lifted_by = p_actor, lifted_at = NOW(), lift_reason_code = p_reason_code WHERE id = v_suspension.id;
  UPDATE organization_memberships SET status = 'active', updated_at = NOW() WHERE id = p_membership AND status = 'suspended';
  v_result := jsonb_build_object('suspensionId', v_suspension.id, 'membershipId', p_membership, 'status', 'lifted');
  RETURN trust_store_result(p_actor, 'membership.resume', p_idempotency_key, p_request_hash, v_result);
END;
$$;

CREATE OR REPLACE FUNCTION create_retention_dry_run(
  p_actor UUID, p_organization UUID, p_policy UUID, p_idempotency_key TEXT, p_request_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_policy data_retention_policies; v_run data_retention_runs; v_result JSONB;
BEGIN
  PERFORM trust_require_platform_admin(p_actor);
  PERFORM pg_advisory_xact_lock(hashtextextended(p_actor::TEXT || ':retention:' || p_idempotency_key, 0));
  v_result := trust_existing_result(p_actor, 'retention.dry_run', p_idempotency_key, p_request_hash);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
  SELECT * INTO v_policy FROM data_retention_policies WHERE id = p_policy;
  IF v_policy.id IS NULL OR v_policy.organization_id IS DISTINCT FROM p_organization THEN RAISE EXCEPTION 'Retention policy not found for scope'; END IF;
  INSERT INTO data_retention_runs(organization_id, policy_id, requested_by, idempotency_key, request_hash)
  VALUES (p_organization, p_policy, p_actor, p_idempotency_key, p_request_hash) RETURNING * INTO v_run;
  v_result := jsonb_build_object('runId', v_run.id, 'mode', 'dry_run', 'status', 'planned');
  RETURN trust_store_result(p_actor, 'retention.dry_run', p_idempotency_key, p_request_hash, v_result);
END;
$$;

INSERT INTO feature_flags(key, domain, description, default_enabled, failure_mode, risk) VALUES
  ('trust.review_cases', 'trust', 'Open, assign, and decide trust review cases.', FALSE, 'closed', 'standard'),
  ('trust.appeals', 'trust', 'File and decide independent trust appeals.', FALSE, 'closed', 'standard'),
  ('trust.suspensions', 'trust', 'Apply and lift decision-backed organization and membership suspensions.', FALSE, 'closed', 'regulated'),
  ('trust.retention.dry_run', 'trust', 'Plan retention effects without changing source records.', FALSE, 'closed', 'standard'),
  ('trust.retention.execute', 'trust', 'Execute retention actions; deliberately unavailable in this increment.', FALSE, 'closed', 'regulated')
ON CONFLICT (key) DO UPDATE SET domain = EXCLUDED.domain, description = EXCLUDED.description,
  default_enabled = EXCLUDED.default_enabled, failure_mode = EXCLUDED.failure_mode,
  risk = EXCLUDED.risk, updated_at = NOW();

ALTER TABLE trust_review_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_review_case_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_review_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_reviewer_conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_appeal_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_suspensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_membership_suspensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_legal_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_retention_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_retention_run_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE trust_idempotency_records ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON trust_review_cases, trust_review_case_events, trust_review_decisions,
  trust_reviewer_conflicts, trust_appeals, trust_appeal_events, organization_suspensions,
  organization_membership_suspensions, data_retention_policies, data_legal_holds,
  data_retention_runs, data_retention_run_items, trust_idempotency_records FROM anon, authenticated;
REVOKE ALL ON FUNCTION trust_require_platform_admin(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION trust_existing_result(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION trust_store_result(UUID, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION open_trust_review_case(UUID, UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION assign_trust_review_case(UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION declare_trust_reviewer_conflict(UUID, UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_trust_review_case(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION file_trust_appeal(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION decide_trust_appeal(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION suspend_trust_organization(UUID, UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION resume_trust_organization(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION suspend_trust_membership(UUID, UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION resume_trust_membership(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION create_retention_dry_run(UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION open_trust_review_case(UUID, UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION assign_trust_review_case(UUID, UUID, UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION declare_trust_reviewer_conflict(UUID, UUID, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION decide_trust_review_case(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION file_trust_appeal(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION decide_trust_appeal(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION suspend_trust_organization(UUID, UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION resume_trust_organization(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION suspend_trust_membership(UUID, UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION resume_trust_membership(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION create_retention_dry_run(UUID, UUID, UUID, TEXT, TEXT) TO service_role;

COMMIT;
