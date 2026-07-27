-- Atomic FC-06 reconciliation ingestion and immutable evidence boundary.

ALTER TABLE reconciliation_runs
  ADD COLUMN IF NOT EXISTS request_hash VARCHAR(64)
    NOT NULL DEFAULT repeat('0', 64)
    CHECK (request_hash ~ '^[a-f0-9]{64}$');
ALTER TABLE reconciliation_runs ALTER COLUMN request_hash DROP DEFAULT;

CREATE OR REPLACE FUNCTION run_payment_reconciliation(
  p_organization_id UUID,
  p_configuration_id UUID,
  p_source_hash TEXT,
  p_period_start TIMESTAMPTZ,
  p_period_end TIMESTAMPTZ,
  p_provider_items JSONB,
  p_started_by UUID,
  p_opening_balance_minor BIGINT,
  p_provider_balance_minor BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_configuration reconciliation_configurations;
  v_existing reconciliation_runs;
  v_run reconciliation_runs;
  v_item JSONB;
  v_ordinal INTEGER := 0;
  v_identity TEXT;
  v_seen_identities TEXT[] := '{}';
  v_provider_reference TEXT;
  v_internal_reference TEXT;
  v_currency TEXT;
  v_direction TEXT;
  v_amount_minor BIGINT;
  v_occurred_at TIMESTAMPTZ;
  v_payment_id UUID;
  v_payout_id UUID;
  v_internal_amount_minor BIGINT;
  v_internal_occurred_at TIMESTAMPTZ;
  v_state TEXT;
  v_reason TEXT;
  v_source_item_hash TEXT;
  v_item_id UUID;
  v_request_hash TEXT;
  v_movement_minor BIGINT;
  v_closing_balance_minor BIGINT;
  v_matched_value_minor BIGINT := 0;
  v_unexplained_variance_minor BIGINT;
  v_matched_count INTEGER := 0;
  v_exception_count INTEGER := 0;
BEGIN
  IF p_source_hash IS NULL OR p_source_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'Reconciliation source hash is invalid';
  END IF;
  IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end < p_period_start THEN
    RAISE EXCEPTION 'Reconciliation period is invalid';
  END IF;
  IF jsonb_typeof(p_provider_items) <> 'array' THEN
    RAISE EXCEPTION 'Reconciliation provider items must be an array';
  END IF;

  SELECT * INTO v_configuration
  FROM reconciliation_configurations
  WHERE id = p_configuration_id AND organization_id = p_organization_id AND enabled
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reconciliation configuration is unavailable'; END IF;
  IF NOT has_financial_permission(p_organization_id, p_started_by, 'financial.reconciliation.manual') THEN
    RAISE EXCEPTION 'Actor cannot run reconciliation for this organization';
  END IF;

  v_request_hash := encode(digest(convert_to(concat_ws('|',
    p_organization_id::TEXT, p_configuration_id::TEXT, p_source_hash,
    extract(epoch FROM p_period_start)::TEXT, extract(epoch FROM p_period_end)::TEXT,
    p_opening_balance_minor::TEXT,
    p_provider_balance_minor::TEXT, p_provider_items::TEXT
  ), 'UTF8'), 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_configuration_id::TEXT || ':' || p_source_hash, 0));
  SELECT * INTO v_existing FROM reconciliation_runs
  WHERE configuration_id = p_configuration_id AND source_hash = p_source_hash;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'Reconciliation source replay changed the original request';
    END IF;
    RETURN to_jsonb(v_existing) || jsonb_build_object(
      'matchedCount', (SELECT count(*) FROM reconciliation_items WHERE run_id = v_existing.id AND state = 'matched'),
      'exceptionCount', (SELECT count(*) FROM reconciliation_exceptions WHERE run_id = v_existing.id)
    );
  END IF;

  SELECT COALESCE(sum(amount_minor), 0) INTO v_movement_minor
  FROM payments
  WHERE organization_id = p_organization_id
    AND provider_name = v_configuration.provider_name
    AND provider_environment = v_configuration.provider_environment
    AND currency = v_configuration.currency
    AND state IN ('succeeded', 'partially_refunded', 'refunded')
    AND terminal_at BETWEEN p_period_start AND p_period_end;
  v_movement_minor := v_movement_minor - COALESCE((
    SELECT sum(amount_minor) FROM payouts
    WHERE organization_id = p_organization_id
      AND provider_name = v_configuration.provider_name
      AND provider_environment = v_configuration.provider_environment
      AND currency = v_configuration.currency
      AND state = 'succeeded'
      AND terminal_at BETWEEN p_period_start AND p_period_end
  ), 0);
  v_closing_balance_minor := p_opening_balance_minor + v_movement_minor;
  v_unexplained_variance_minor := v_closing_balance_minor - p_provider_balance_minor;

  INSERT INTO reconciliation_runs(
    organization_id, configuration_id, source_hash, request_hash, period_start, period_end,
    state, opening_balance_minor, movement_minor, closing_balance_minor,
    provider_balance_minor, matched_value_minor, unexplained_variance_minor, started_by
  ) VALUES (
    p_organization_id, p_configuration_id, p_source_hash, v_request_hash, p_period_start, p_period_end,
    'running', p_opening_balance_minor, v_movement_minor, v_closing_balance_minor,
    p_provider_balance_minor, 0, v_unexplained_variance_minor, p_started_by
  ) RETURNING * INTO v_run;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_provider_items) LOOP
    v_ordinal := v_ordinal + 1;
    IF jsonb_typeof(v_item) <> 'object'
      OR COALESCE(v_item->>'providerReference', '') = ''
      OR COALESCE(v_item->>'internalReference', '') = ''
      OR COALESCE(v_item->>'currency', '') !~ '^[A-Z]{3}$'
      OR COALESCE(v_item->>'direction', '') NOT IN ('inbound', 'outbound')
      OR COALESCE(v_item->>'amountMinor', '') !~ '^[1-9][0-9]*$'
      OR COALESCE(v_item->>'occurredAt', '') = '' THEN
      RAISE EXCEPTION 'Reconciliation provider item % is invalid', v_ordinal;
    END IF;
    v_provider_reference := v_item->>'providerReference';
    v_internal_reference := v_item->>'internalReference';
    v_currency := v_item->>'currency';
    v_direction := v_item->>'direction';
    v_amount_minor := (v_item->>'amountMinor')::BIGINT;
    v_occurred_at := (v_item->>'occurredAt')::TIMESTAMPTZ;
    IF v_occurred_at < p_period_start OR v_occurred_at > p_period_end THEN
      RAISE EXCEPTION 'Reconciliation provider item is outside the run period';
    END IF;
    IF v_currency <> v_configuration.currency THEN
      RAISE EXCEPTION 'Reconciliation provider item currency does not match configuration';
    END IF;

    v_identity := concat_ws('|', v_provider_reference, v_internal_reference, v_currency, v_direction);
    v_payment_id := NULL; v_payout_id := NULL; v_internal_amount_minor := NULL; v_internal_occurred_at := NULL;
    IF v_identity = ANY(v_seen_identities) THEN
      v_state := 'duplicate'; v_reason := 'Duplicate provider identity';
    ELSE
      v_seen_identities := array_append(v_seen_identities, v_identity);
      IF v_direction = 'inbound' THEN
        SELECT id, amount_minor, terminal_at INTO v_payment_id, v_internal_amount_minor, v_internal_occurred_at
        FROM payments
        WHERE organization_id = p_organization_id
          AND provider_name = v_configuration.provider_name
          AND provider_environment = v_configuration.provider_environment
          AND provider_reference = v_provider_reference
          AND internal_reference = v_internal_reference
          AND currency = v_currency
          AND state IN ('succeeded', 'partially_refunded', 'refunded')
          AND terminal_at BETWEEN p_period_start AND p_period_end;
      ELSE
        SELECT id, amount_minor, terminal_at INTO v_payout_id, v_internal_amount_minor, v_internal_occurred_at
        FROM payouts
        WHERE organization_id = p_organization_id
          AND provider_name = v_configuration.provider_name
          AND provider_environment = v_configuration.provider_environment
          AND provider_reference = v_provider_reference
          AND internal_reference = v_internal_reference
          AND currency = v_currency
          AND state = 'succeeded'
          AND terminal_at BETWEEN p_period_start AND p_period_end;
      END IF;
      IF v_internal_amount_minor IS NULL THEN
        v_state := 'unmatched'; v_reason := 'No exact internal reference match';
      ELSIF v_internal_amount_minor <> v_amount_minor THEN
        v_state := 'mismatch'; v_reason := 'Amount mismatch';
      ELSIF abs(extract(epoch FROM (v_internal_occurred_at - v_occurred_at)))
        > v_configuration.date_window_hours * 3600 THEN
        v_state := 'late'; v_reason := 'Outside approved date window';
      ELSE
        v_state := 'matched'; v_reason := NULL;
        v_matched_count := v_matched_count + 1;
        v_matched_value_minor := v_matched_value_minor + v_amount_minor;
      END IF;
    END IF;

    v_source_item_hash := encode(digest(convert_to(v_ordinal::TEXT || ':' || v_item::TEXT, 'UTF8'), 'sha256'), 'hex');
    INSERT INTO reconciliation_items(
      organization_id, run_id, payout_id, payment_id, provider_reference, internal_reference,
      direction, currency, amount_minor, occurred_at, source_item_hash, state, mismatch_reason
    ) VALUES (
      p_organization_id, v_run.id, v_payout_id, v_payment_id, v_provider_reference, v_internal_reference,
      v_direction, v_currency, v_amount_minor, v_occurred_at, v_source_item_hash, v_state, v_reason
    ) RETURNING id INTO v_item_id;
    IF v_state <> 'matched' THEN
      INSERT INTO reconciliation_exceptions(organization_id, run_id, item_id, reason)
      VALUES (p_organization_id, v_run.id, v_item_id, v_reason);
      v_exception_count := v_exception_count + 1;
    END IF;
  END LOOP;

  UPDATE reconciliation_runs SET state = 'completed', matched_value_minor = v_matched_value_minor,
    completed_at = NOW() WHERE id = v_run.id RETURNING * INTO v_run;
  RETURN to_jsonb(v_run) || jsonb_build_object(
    'matchedCount', v_matched_count, 'exceptionCount', v_exception_count
  );
END;
$$;

REVOKE INSERT, UPDATE, DELETE ON reconciliation_runs, reconciliation_items, reconciliation_exceptions
  FROM service_role;
REVOKE ALL ON FUNCTION run_payment_reconciliation(UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, JSONB, UUID, BIGINT, BIGINT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION run_payment_reconciliation(UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, JSONB, UUID, BIGINT, BIGINT)
  TO service_role;

DO $$
DECLARE protected_table TEXT;
BEGIN
  FOREACH protected_table IN ARRAY ARRAY['reconciliation_runs', 'reconciliation_items', 'reconciliation_exceptions'] LOOP
    IF has_table_privilege('service_role', protected_table, 'INSERT')
      OR has_table_privilege('service_role', protected_table, 'UPDATE')
      OR has_table_privilege('service_role', protected_table, 'DELETE') THEN
      RAISE EXCEPTION 'service_role has direct DML privilege on %', protected_table;
    END IF;
    IF NOT has_table_privilege('service_role', protected_table, 'SELECT') THEN
      RAISE EXCEPTION 'service_role cannot service existing % records', protected_table;
    END IF;
  END LOOP;
END $$;
