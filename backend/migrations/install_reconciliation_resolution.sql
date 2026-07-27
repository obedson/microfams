-- FC-06/FC-11 maker-checker reconciliation resolution and write-off workflow.
ALTER TABLE financial_approval_requests DROP CONSTRAINT financial_approval_requests_action_type_check;
ALTER TABLE financial_approval_requests ADD CONSTRAINT financial_approval_requests_action_type_check
CHECK (action_type IN ('rule_activation','limit_increase','manual_adjustment','live_activation','regulated_feature_override','reconciliation_resolution','reconciliation_writeoff','period_reopen'));

CREATE TABLE reconciliation_resolution_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
  exception_id UUID NOT NULL REFERENCES reconciliation_exceptions(id),
  resolution_type TEXT NOT NULL CHECK (resolution_type IN ('matched_evidence','provider_correction','compensating_adjustment','writeoff')),
  resolution_reason TEXT NOT NULL CHECK (length(btrim(resolution_reason)) BETWEEN 10 AND 500),
  evidence_reference TEXT NOT NULL CHECK (length(btrim(evidence_reference)) BETWEEN 4 AND 500),
  compensating_journal_entry_id UUID REFERENCES journal_entries(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','approved','rejected')),
  requested_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT, requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  approval_request_id UUID UNIQUE REFERENCES financial_approval_requests(id), decided_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  decided_at TIMESTAMPTZ, decision_reason TEXT, UNIQUE (organization_id,idempotency_key),
  CHECK ((resolution_type IN ('compensating_adjustment','writeoff') AND compensating_journal_entry_id IS NOT NULL)
    OR resolution_type IN ('matched_evidence','provider_correction')),
  CHECK ((state='pending' AND decided_by IS NULL AND decided_at IS NULL AND decision_reason IS NULL)
    OR (state IN ('approved','rejected') AND decided_by IS NOT NULL AND decided_at IS NOT NULL AND decision_reason IS NOT NULL)),
  CHECK (decided_by IS NULL OR decided_by<>requested_by)
);
CREATE UNIQUE INDEX uq_reconciliation_resolution_pending ON reconciliation_resolution_requests(exception_id) WHERE state='pending';
CREATE UNIQUE INDEX uq_reconciliation_compensating_journal ON reconciliation_resolution_requests(compensating_journal_entry_id)
  WHERE compensating_journal_entry_id IS NOT NULL AND state='approved';
ALTER TABLE reconciliation_resolution_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY reconciliation_resolution_tenant_read ON reconciliation_resolution_requests FOR SELECT USING (has_active_organization_membership(organization_id));
UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT p FROM unnest(permissions||ARRAY['financial.reconciliation.approve']) p) WHERE role='owner';

CREATE OR REPLACE FUNCTION validate_reconciliation_compensating_journal(p_org UUID,p_journal UUID,p_required BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v journal_entries;
BEGIN
 IF p_journal IS NULL THEN IF p_required THEN RAISE EXCEPTION 'A compensating journal is required for this resolution type'; END IF; RETURN; END IF;
 SELECT * INTO v FROM journal_entries WHERE id=p_journal AND organization_id=p_org;
 IF v.id IS NULL THEN RAISE EXCEPTION 'Compensating journal was not found in this organization'; END IF;
 IF v.status<>'posted' THEN RAISE EXCEPTION 'Compensating journal must be posted'; END IF;
 IF v.source_domain NOT IN ('reconciliation.adjustment','reconciliation.writeoff') THEN RAISE EXCEPTION 'Compensating journal must use a reconciliation source domain'; END IF;
END $$;

CREATE OR REPLACE FUNCTION request_reconciliation_exception_resolution(p_exception UUID,p_actor UUID,p_type TEXT,p_reason TEXT,p_evidence TEXT,p_journal UUID,p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e reconciliation_exceptions; old reconciliation_resolution_requests; r reconciliation_resolution_requests; approval UUID; h TEXT; reason TEXT:=btrim(p_reason); evidence TEXT:=btrim(p_evidence); action TEXT;
BEGIN
 IF p_type NOT IN ('matched_evidence','provider_correction','compensating_adjustment','writeoff') THEN RAISE EXCEPTION 'Reconciliation resolution type is invalid'; END IF;
 IF reason IS NULL OR length(reason) NOT BETWEEN 10 AND 500 THEN RAISE EXCEPTION 'Resolution reason must be between 10 and 500 characters'; END IF;
 IF evidence IS NULL OR length(evidence) NOT BETWEEN 4 AND 500 THEN RAISE EXCEPTION 'Evidence reference must be between 4 and 500 characters'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
 SELECT * INTO e FROM reconciliation_exceptions WHERE id=p_exception;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Reconciliation exception not found'; END IF;
 IF NOT has_financial_permission(e.organization_id,p_actor,'financial.reconciliation.manual') THEN RAISE EXCEPTION 'Missing financial.reconciliation.manual permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_exception::TEXT,p_actor::TEXT,p_type,reason,evidence,COALESCE(p_journal::TEXT,'')),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(e.organization_id::TEXT||':reconciliation-resolution:'||p_key,0));
 SELECT * INTO old FROM reconciliation_resolution_requests WHERE organization_id=e.organization_id AND idempotency_key=p_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with a different resolution request'; END IF; RETURN to_jsonb(old); END IF;
 SELECT * INTO e FROM reconciliation_exceptions WHERE id=p_exception FOR UPDATE;
 IF e.state<>'investigating' THEN RAISE EXCEPTION 'Only an investigating reconciliation exception can be resolved'; END IF;
 PERFORM validate_reconciliation_compensating_journal(e.organization_id,p_journal,p_type IN ('compensating_adjustment','writeoff'));
 IF p_journal IS NOT NULL AND EXISTS(SELECT 1 FROM reconciliation_resolution_requests WHERE compensating_journal_entry_id=p_journal AND state='approved') THEN RAISE EXCEPTION 'Compensating journal has already been used'; END IF;
 INSERT INTO reconciliation_resolution_requests(organization_id,exception_id,resolution_type,resolution_reason,evidence_reference,compensating_journal_entry_id,idempotency_key,request_hash,requested_by)
 VALUES(e.organization_id,e.id,p_type,reason,evidence,p_journal,p_key,h,p_actor) RETURNING * INTO r;
 action:=CASE WHEN p_type='writeoff' THEN 'reconciliation_writeoff' ELSE 'reconciliation_resolution' END;
 INSERT INTO financial_approval_requests(organization_id,action_type,resource_type,resource_id,requested_by,reason)
 VALUES(e.organization_id,action,'reconciliation_resolution_request',r.id,p_actor,reason) RETURNING id INTO approval;
 UPDATE reconciliation_resolution_requests SET approval_request_id=approval WHERE id=r.id RETURNING * INTO r;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value)
 VALUES(e.organization_id,p_actor,'RECONCILIATION_RESOLUTION_REQUESTED','reconciliation_resolution_request',r.id::TEXT,
 jsonb_build_object('exception_id',e.id,'resolution_type',p_type,'approval_request_id',approval,'evidence_reference',evidence));
 RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION decide_reconciliation_exception_resolution(p_request UUID,p_actor UUID,p_approve BOOLEAN,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r reconciliation_resolution_requests; e reconciliation_exceptions; a financial_approval_requests; reason TEXT:=btrim(p_reason); target TEXT:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END; expected TEXT;
BEGIN
 IF p_approve IS NULL THEN RAISE EXCEPTION 'Approval decision is required'; END IF;
 IF reason IS NULL OR length(reason) NOT BETWEEN 10 AND 500 THEN RAISE EXCEPTION 'Decision reason must be between 10 and 500 characters'; END IF;
 SELECT * INTO r FROM reconciliation_resolution_requests WHERE id=p_request FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Reconciliation resolution request not found'; END IF;
 IF NOT has_financial_permission(r.organization_id,p_actor,'financial.reconciliation.approve') THEN RAISE EXCEPTION 'Missing financial.reconciliation.approve permission'; END IF;
 IF r.requested_by=p_actor THEN RAISE EXCEPTION 'Maker cannot decide their own reconciliation resolution'; END IF;
 IF r.state<>'pending' THEN IF r.state=target AND r.decided_by=p_actor AND r.decision_reason=reason THEN RETURN to_jsonb(r); END IF; RAISE EXCEPTION 'Resolution decision replay changed the original facts'; END IF;
 SELECT * INTO e FROM reconciliation_exceptions WHERE id=r.exception_id AND organization_id=r.organization_id FOR UPDATE;
 IF e.id IS NULL OR e.state<>'investigating' THEN RAISE EXCEPTION 'Reconciliation exception is no longer eligible for resolution'; END IF;
 SELECT * INTO a FROM financial_approval_requests WHERE id=r.approval_request_id FOR UPDATE;
 expected:=CASE WHEN r.resolution_type='writeoff' THEN 'reconciliation_writeoff' ELSE 'reconciliation_resolution' END;
 IF a.id IS NULL OR a.organization_id<>r.organization_id OR a.resource_id<>r.id OR a.resource_type<>'reconciliation_resolution_request' OR a.action_type<>expected OR a.state<>'pending' THEN RAISE EXCEPTION 'Financial approval request is invalid'; END IF;
 IF p_approve THEN
  PERFORM validate_reconciliation_compensating_journal(r.organization_id,r.compensating_journal_entry_id,r.resolution_type IN ('compensating_adjustment','writeoff'));
  IF r.compensating_journal_entry_id IS NOT NULL AND EXISTS(SELECT 1 FROM reconciliation_resolution_requests WHERE compensating_journal_entry_id=r.compensating_journal_entry_id AND state='approved' AND id<>r.id) THEN RAISE EXCEPTION 'Compensating journal has already been used'; END IF;
  UPDATE reconciliation_exceptions SET state='resolved',resolution_reason=r.resolution_reason,evidence_reference=r.evidence_reference,compensating_journal_entry_id=r.compensating_journal_entry_id,resolved_by=p_actor,resolved_at=NOW() WHERE id=e.id;
  UPDATE reconciliation_items SET state='resolved' WHERE id=e.item_id;
 END IF;
 UPDATE financial_approval_requests SET state=target,decided_by=p_actor,decided_at=NOW() WHERE id=a.id;
 UPDATE reconciliation_resolution_requests SET state=target,decided_by=p_actor,decided_at=NOW(),decision_reason=reason WHERE id=r.id RETURNING * INTO r;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value)
 VALUES(r.organization_id,p_actor,CASE WHEN p_approve THEN 'RECONCILIATION_RESOLUTION_APPROVED' ELSE 'RECONCILIATION_RESOLUTION_REJECTED' END,
 'reconciliation_resolution_request',r.id::TEXT,jsonb_build_object('exception_id',r.exception_id,'resolution_type',r.resolution_type,'state',target,'approval_request_id',r.approval_request_id));
 RETURN to_jsonb(r);
END $$;

REVOKE ALL ON TABLE reconciliation_resolution_requests FROM anon,authenticated;
GRANT SELECT ON TABLE reconciliation_resolution_requests TO service_role;
REVOKE INSERT,UPDATE,DELETE ON TABLE reconciliation_resolution_requests FROM service_role;
REVOKE ALL ON FUNCTION validate_reconciliation_compensating_journal(UUID,UUID,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_reconciliation_exception_resolution(UUID,UUID,TEXT,TEXT,TEXT,UUID,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_reconciliation_exception_resolution(UUID,UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION request_reconciliation_exception_resolution(UUID,UUID,TEXT,TEXT,TEXT,UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION decide_reconciliation_exception_resolution(UUID,UUID,BOOLEAN,TEXT) TO service_role;
DO $$ BEGIN
 IF has_table_privilege('service_role','reconciliation_resolution_requests','INSERT') OR has_table_privilege('service_role','reconciliation_resolution_requests','UPDATE') OR has_table_privilege('service_role','reconciliation_resolution_requests','DELETE') THEN RAISE EXCEPTION 'service_role can directly mutate reconciliation resolution requests'; END IF;
 IF NOT has_table_privilege('service_role','reconciliation_resolution_requests','SELECT') THEN RAISE EXCEPTION 'service_role cannot service reconciliation resolution requests'; END IF;
END $$;
