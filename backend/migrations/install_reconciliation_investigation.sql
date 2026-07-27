-- Authorized FC-06 reconciliation exception investigation workflow.

ALTER TABLE reconciliation_exceptions
  ADD COLUMN IF NOT EXISTS investigation_started_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS investigation_reason TEXT,
  ADD COLUMN IF NOT EXISTS investigation_started_at TIMESTAMPTZ;

ALTER TABLE reconciliation_exceptions
  ADD CONSTRAINT reconciliation_exception_investigation_shape CHECK (
    (state = 'open' AND investigation_started_by IS NULL
      AND investigation_reason IS NULL AND investigation_started_at IS NULL)
    OR state = 'resolved'
    OR (state = 'investigating' AND investigation_started_by IS NOT NULL
      AND investigation_reason IS NOT NULL AND investigation_started_at IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION start_reconciliation_exception_investigation(
  p_exception_id UUID,
  p_actor_id UUID,
  p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_exception reconciliation_exceptions;
  v_item reconciliation_items;
  v_reason TEXT := btrim(p_reason);
BEGIN
  SELECT * INTO v_exception FROM reconciliation_exceptions
  WHERE id = p_exception_id FOR UPDATE;
  IF v_exception.id IS NULL THEN RAISE EXCEPTION 'Reconciliation exception not found'; END IF;
  IF NOT has_financial_permission(
    v_exception.organization_id, p_actor_id, 'financial.reconciliation.manual'
  ) THEN RAISE EXCEPTION 'Missing financial.reconciliation.manual permission'; END IF;
  IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 10 AND 500 THEN
    RAISE EXCEPTION 'Investigation reason must be between 10 and 500 characters';
  END IF;
  IF v_exception.state = 'resolved' THEN
    RAISE EXCEPTION 'Resolved reconciliation exception cannot be reopened';
  END IF;
  IF v_exception.state = 'investigating' THEN
    IF v_exception.investigation_started_by <> p_actor_id
      OR v_exception.investigation_reason <> v_reason THEN
      RAISE EXCEPTION 'Investigation replay changed the original facts';
    END IF;
    RETURN to_jsonb(v_exception);
  END IF;

  SELECT * INTO v_item FROM reconciliation_items
  WHERE id = v_exception.item_id AND run_id = v_exception.run_id
    AND organization_id = v_exception.organization_id FOR UPDATE;
  IF v_item.id IS NULL OR v_item.state NOT IN ('unmatched', 'mismatch', 'duplicate', 'late') THEN
    RAISE EXCEPTION 'Reconciliation item is not eligible for investigation';
  END IF;

  UPDATE reconciliation_items SET state = 'investigating'
  WHERE id = v_item.id;
  UPDATE reconciliation_exceptions SET
    state = 'investigating', investigation_started_by = p_actor_id,
    investigation_reason = v_reason, investigation_started_at = NOW()
  WHERE id = v_exception.id RETURNING * INTO v_exception;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_exception.organization_id, p_actor_id, 'RECONCILIATION_INVESTIGATION_STARTED',
    'reconciliation_exception', v_exception.id::TEXT,
    jsonb_build_object('state', 'investigating', 'item_id', v_exception.item_id)
  );
  RETURN to_jsonb(v_exception);
END;
$$;

REVOKE ALL ON FUNCTION start_reconciliation_exception_investigation(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_reconciliation_exception_investigation(UUID, UUID, TEXT) TO service_role;
