DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  outsider_id CONSTANT UUID := '00000000-0000-4000-8000-000000000104';
  exception_id UUID;
  item_id UUID;
  result JSONB;
  replay JSONB;
  reason CONSTANT TEXT := 'Investigate duplicate provider evidence before close';
BEGIN
  SELECT id, reconciliation_exceptions.item_id INTO exception_id, item_id
  FROM reconciliation_exceptions WHERE organization_id = tenant_id AND state = 'open'
  ORDER BY created_at LIMIT 1;
  IF exception_id IS NULL THEN RAISE EXCEPTION 'reconciliation exception fixture is missing'; END IF;

  BEGIN
    PERFORM start_reconciliation_exception_investigation(exception_id, actor_id, 'short');
    RAISE EXCEPTION 'short investigation reason was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'short investigation reason was accepted' THEN RAISE; END IF;
  END;

  result := start_reconciliation_exception_investigation(exception_id, actor_id, reason);
  replay := start_reconciliation_exception_investigation(exception_id, actor_id, reason);
  IF result->>'state' <> 'investigating' OR replay->>'id' <> result->>'id'
    OR (SELECT state FROM reconciliation_items WHERE id = item_id) <> 'investigating'
    OR (SELECT investigation_started_by FROM reconciliation_exceptions WHERE id = exception_id) <> actor_id
    OR (SELECT investigation_reason FROM reconciliation_exceptions WHERE id = exception_id) <> reason THEN
    RAISE EXCEPTION 'reconciliation investigation transition was not atomic and idempotent';
  END IF;

  BEGIN
    PERFORM start_reconciliation_exception_investigation(exception_id, actor_id, reason || ' changed');
    RAISE EXCEPTION 'investigation replay accepted changed facts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'investigation replay accepted changed facts' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM start_reconciliation_exception_investigation(exception_id, outsider_id, reason);
    RAISE EXCEPTION 'cross-tenant actor started reconciliation investigation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant actor started reconciliation investigation' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM organization_audit_log
      WHERE resource_type = 'reconciliation_exception' AND resource_id = exception_id::TEXT
        AND action = 'RECONCILIATION_INVESTIGATION_STARTED') <> 1 THEN
    RAISE EXCEPTION 'reconciliation investigation audit event is missing or duplicated';
  END IF;
END $$;

SET ROLE service_role;
DO $$ BEGIN
  BEGIN
    UPDATE reconciliation_exceptions SET investigation_reason = 'forged investigation reason'
    WHERE state = 'investigating';
    RAISE EXCEPTION 'service role directly changed reconciliation investigation evidence';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'service role directly changed reconciliation investigation evidence' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
