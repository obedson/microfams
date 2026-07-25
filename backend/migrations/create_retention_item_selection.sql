-- Deterministic, non-destructive selection of retention dry-run items.
BEGIN;
ALTER TABLE data_retention_run_items
 ADD COLUMN policy_id UUID REFERENCES data_retention_policies(id) ON DELETE RESTRICT,
 ADD COLUMN data_class TEXT CHECK(data_class IS NULL OR data_class ~ '^[a-z][a-z0-9_.]{2,63}$'),
 ADD COLUMN source_created_at TIMESTAMPTZ,
 ADD COLUMN legal_hold_id UUID REFERENCES data_legal_holds(id) ON DELETE RESTRICT;
CREATE INDEX idx_retention_run_items_run_action ON data_retention_run_items(run_id,proposed_action);
CREATE TRIGGER data_retention_run_items_append_only BEFORE UPDATE OR DELETE ON data_retention_run_items FOR EACH ROW EXECUTE FUNCTION protect_trust_append_only();
CREATE OR REPLACE FUNCTION protect_data_retention_run() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='planned' AND NEW.status IN('completed','failed')
  AND (to_jsonb(OLD)-'status'-'completed_at'-'summary')=(to_jsonb(NEW)-'status'-'completed_at'-'summary')
  AND NEW.completed_at IS NOT NULL AND jsonb_typeof(NEW.summary)='object' THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'Retention run evidence is immutable';
END; $$;
CREATE TRIGGER data_retention_runs_terminal_history BEFORE UPDATE OR DELETE ON data_retention_runs FOR EACH ROW EXECUTE FUNCTION protect_data_retention_run();
CREATE OR REPLACE FUNCTION select_retention_dry_run_items(p_actor UUID,p_run UUID,p_idempotency_key TEXT,p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r data_retention_runs; p data_retention_policies; result JSONB; v_summary JSONB; cutoff TIMESTAMPTZ;
BEGIN
 PERFORM trust_require_platform_admin(p_actor);
 PERFORM pg_advisory_xact_lock(hashtextextended('retention-selection:'||p_run::TEXT,0));
 result:=trust_existing_result(p_actor,'retention.select_items',p_idempotency_key,p_request_hash); IF result IS NOT NULL THEN RETURN result; END IF;
 SELECT * INTO r FROM data_retention_runs WHERE id=p_run FOR UPDATE;
 IF r.id IS NULL OR r.mode<>'dry_run' THEN RAISE EXCEPTION 'Retention dry run not found'; END IF;
 IF r.status<>'planned' THEN RAISE EXCEPTION 'Retention dry run is already terminal'; END IF;
 SELECT * INTO p FROM data_retention_policies WHERE id=r.policy_id;
 IF p.id IS NULL OR NOT p.enabled OR p.organization_id IS DISTINCT FROM r.organization_id THEN RAISE EXCEPTION 'Enabled retention policy not found for scope'; END IF;
 IF p.data_class NOT IN('trust.case_metadata','trust.appeal_metadata') THEN RAISE EXCEPTION 'Unsupported retention data class'; END IF;
 cutoff:=NOW()-make_interval(days=>p.retention_days);
 IF p.data_class='trust.case_metadata' THEN
  INSERT INTO data_retention_run_items(run_id,organization_id,resource_type,resource_id,proposed_action,reason_code,policy_id,data_class,source_created_at,legal_hold_id)
  SELECT r.id,c.organization_id,'trust_case',c.id::TEXT,
   CASE WHEN h.id IS NOT NULL THEN 'held' WHEN p.disposition='review' THEN 'retain' WHEN p.disposition='anonymize' THEN 'would_anonymize' ELSE 'would_delete' END,
   CASE WHEN h.id IS NOT NULL THEN 'ACTIVE_LEGAL_HOLD' WHEN p.disposition='review' THEN 'MANUAL_REVIEW_REQUIRED' WHEN p.disposition='anonymize' THEN 'POLICY_WOULD_ANONYMIZE' ELSE 'POLICY_WOULD_DELETE' END,
   p.id,p.data_class,c.opened_at,h.id
  FROM trust_review_cases c LEFT JOIN LATERAL(
   SELECT hold.id FROM data_legal_holds hold WHERE hold.status='active' AND hold.organization_id IS NOT DISTINCT FROM c.organization_id
    AND ((hold.subject_type='case' AND hold.subject_id=c.id::TEXT) OR (hold.subject_type='data_class' AND hold.subject_id=p.data_class))
   ORDER BY CASE WHEN hold.subject_type='case' THEN 0 ELSE 1 END,hold.placed_at LIMIT 1) h ON TRUE
  WHERE c.organization_id IS NOT DISTINCT FROM r.organization_id AND c.opened_at<cutoff;
 ELSE
  INSERT INTO data_retention_run_items(run_id,organization_id,resource_type,resource_id,proposed_action,reason_code,policy_id,data_class,source_created_at,legal_hold_id)
  SELECT r.id,a.organization_id,'trust_appeal',a.id::TEXT,
   CASE WHEN h.id IS NOT NULL THEN 'held' WHEN p.disposition='review' THEN 'retain' WHEN p.disposition='anonymize' THEN 'would_anonymize' ELSE 'would_delete' END,
   CASE WHEN h.id IS NOT NULL THEN 'ACTIVE_LEGAL_HOLD' WHEN p.disposition='review' THEN 'MANUAL_REVIEW_REQUIRED' WHEN p.disposition='anonymize' THEN 'POLICY_WOULD_ANONYMIZE' ELSE 'POLICY_WOULD_DELETE' END,
   p.id,p.data_class,a.filed_at,h.id
  FROM trust_appeals a LEFT JOIN LATERAL(
   SELECT hold.id FROM data_legal_holds hold WHERE hold.status='active' AND hold.organization_id IS NOT DISTINCT FROM a.organization_id
    AND ((hold.subject_type='case' AND hold.subject_id=a.case_id::TEXT) OR (hold.subject_type='data_class' AND hold.subject_id=p.data_class))
   ORDER BY CASE WHEN hold.subject_type='case' THEN 0 ELSE 1 END,hold.placed_at LIMIT 1) h ON TRUE
  WHERE a.organization_id IS NOT DISTINCT FROM r.organization_id AND a.filed_at<cutoff;
 END IF;
 SELECT jsonb_build_object('total',count(*),'held',count(*) FILTER(WHERE proposed_action='held'),'retained',count(*) FILTER(WHERE proposed_action='retain'),'wouldAnonymize',count(*) FILTER(WHERE proposed_action='would_anonymize'),'wouldDelete',count(*) FILTER(WHERE proposed_action='would_delete'),'excluded',count(*) FILTER(WHERE proposed_action='excluded'),'dataClass',p.data_class,'cutoffAt',cutoff)
 INTO v_summary FROM data_retention_run_items WHERE run_id=r.id;
 UPDATE data_retention_runs SET status='completed',completed_at=NOW(),summary=v_summary WHERE id=r.id;
 result:=jsonb_build_object('runId',r.id,'mode','dry_run','status','completed','summary',v_summary);
 RETURN trust_store_result(p_actor,'retention.select_items',p_idempotency_key,p_request_hash,result);
END; $$;
REVOKE ALL ON FUNCTION select_retention_dry_run_items(UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION select_retention_dry_run_items(UUID,UUID,TEXT,TEXT) TO service_role;
COMMIT;