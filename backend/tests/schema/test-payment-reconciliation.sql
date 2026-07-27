DO $$
DECLARE
  tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  other_tenant_id CONSTANT UUID := '00000000-0000-4000-8000-000000000103';
  actor_id CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  configuration_id UUID;
  payment payments;
  provider_items JSONB;
  duplicate_items JSONB;
  period_start TIMESTAMPTZ := NOW() - INTERVAL '1 hour';
  period_end TIMESTAMPTZ := NOW() + INTERVAL '1 hour';
  result JSONB;
  replay JSONB;
  reconciliation_run_id UUID;
BEGIN
  SELECT * INTO payment FROM payments WHERE internal_reference = 'PAY-schema-success-001';
  IF payment.id IS NULL THEN RAISE EXCEPTION 'reconciliation payment fixture is missing'; END IF;

  INSERT INTO reconciliation_configurations(
    organization_id, provider_name, provider_environment, currency, date_window_hours, enabled
  ) VALUES (tenant_id, 'deterministic', 'deterministic', 'NGN', 24, TRUE)
  ON CONFLICT (organization_id, provider_name, provider_environment, currency)
  DO UPDATE SET enabled = TRUE, date_window_hours = EXCLUDED.date_window_hours
  RETURNING id INTO configuration_id;

  provider_items := jsonb_build_array(jsonb_build_object(
    'providerReference', payment.provider_reference,
    'internalReference', payment.internal_reference,
    'amountMinor', payment.amount_minor,
    'currency', payment.currency,
    'direction', 'inbound',
    'occurredAt', payment.terminal_at
  ));

  result := run_payment_reconciliation(
    tenant_id, configuration_id, repeat('6', 64), period_start, period_end,
    provider_items, actor_id, 0, 0
  );
  reconciliation_run_id := (result->>'id')::UUID;
  IF result->>'state' <> 'completed' OR (result->>'matchedCount')::INTEGER <> 1
    OR (result->>'exceptionCount')::INTEGER <> 0
    OR (SELECT count(*) FROM reconciliation_items WHERE run_id = reconciliation_run_id) <> 1 THEN
    RAISE EXCEPTION 'atomic reconciliation did not persist the matched run';
  END IF;

  replay := run_payment_reconciliation(
    tenant_id, configuration_id, repeat('6', 64), period_start, period_end,
    provider_items, actor_id, 0, 0
  );
  IF replay->>'id' <> result->>'id'
    OR (SELECT count(*) FROM reconciliation_items WHERE run_id = reconciliation_run_id) <> 1 THEN
    RAISE EXCEPTION 'reconciliation replay was not idempotent';
  END IF;
  BEGIN
    PERFORM run_payment_reconciliation(
      tenant_id, configuration_id, repeat('6', 64), period_start, period_end,
      jsonb_set(provider_items, '{0,amountMinor}', to_jsonb(payment.amount_minor + 1)), actor_id, 0, 0
    );
    RAISE EXCEPTION 'reconciliation replay accepted changed source facts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'reconciliation replay accepted changed source facts' THEN RAISE; END IF;
  END;

  duplicate_items := provider_items || provider_items;
  result := run_payment_reconciliation(
    tenant_id, configuration_id, repeat('7', 64), period_start, period_end,
    duplicate_items, actor_id, 0, 0
  );
  reconciliation_run_id := (result->>'id')::UUID;
  IF (result->>'matchedCount')::INTEGER <> 1 OR (result->>'exceptionCount')::INTEGER <> 1
    OR (SELECT count(*) FROM reconciliation_items WHERE run_id = reconciliation_run_id) <> 2
    OR NOT EXISTS (SELECT 1 FROM reconciliation_items WHERE run_id = reconciliation_run_id AND state = 'duplicate') THEN
    RAISE EXCEPTION 'duplicate provider evidence was not preserved and classified';
  END IF;

  BEGIN
    PERFORM run_payment_reconciliation(
      tenant_id, configuration_id, repeat('8', 64), period_start, period_end,
      provider_items || jsonb_build_array(jsonb_build_object('amountMinor', 'invalid')),
      actor_id, 0, 0
    );
    RAISE EXCEPTION 'invalid reconciliation source was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'invalid reconciliation source was accepted' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM reconciliation_runs WHERE source_hash = repeat('8', 64)) THEN
    RAISE EXCEPTION 'failed reconciliation left partial run evidence';
  END IF;

  BEGIN
    PERFORM run_payment_reconciliation(
      other_tenant_id, configuration_id, repeat('9', 64), period_start, period_end,
      provider_items, actor_id, 0, 0
    );
    RAISE EXCEPTION 'reconciliation accepted a cross-tenant configuration';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'reconciliation accepted a cross-tenant configuration' THEN RAISE; END IF;
  END;
END $$;

SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    UPDATE reconciliation_runs SET state = 'failed' WHERE source_hash = repeat('6', 64);
    RAISE EXCEPTION 'service role directly mutated reconciliation evidence';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'service role directly mutated reconciliation evidence' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;

GRANT SELECT ON reconciliation_runs, reconciliation_items, reconciliation_exceptions TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM reconciliation_runs) <> 2 THEN
    RAISE EXCEPTION 'tenant cannot read its reconciliation evidence';
  END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM reconciliation_runs) <> 0
    OR (SELECT count(*) FROM reconciliation_items) <> 0
    OR (SELECT count(*) FROM reconciliation_exceptions) <> 0 THEN
    RAISE EXCEPTION 'reconciliation evidence leaked across tenants';
  END IF;
END $$;
RESET ROLE;
