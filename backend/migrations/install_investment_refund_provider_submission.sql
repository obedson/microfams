-- INV-09: durable investment refund provider attempts and submission evidence.
-- Provider success posting, callbacks, recovery, reconciliation, and reversal remain disabled.
SET search_path=public,extensions;

CREATE TABLE investment_refund_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  obligation_id UUID NOT NULL,
  attempt_number INTEGER NOT NULL CHECK(attempt_number>0),
  actor_id UUID NOT NULL REFERENCES users(id),
  correlation_id UUID NOT NULL,
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL CHECK(provider_environment IN ('deterministic','sandbox','live')),
  state TEXT NOT NULL CHECK(state IN ('prepared','submitted','processing','unknown','failed','manual_review')),
  provider_reported_state TEXT CHECK(provider_reported_state IN ('submitted','processing','succeeded','failed','cancelled')),
  provider_reference_hash VARCHAR(64) CHECK(provider_reference_hash IS NULL OR provider_reference_hash~'^[a-f0-9]{64}$'),
  provider_reference_masked TEXT,
  reported_amount_minor BIGINT CHECK(reported_amount_minor IS NULL OR reported_amount_minor>0),
  reported_currency VARCHAR(3) CHECK(reported_currency IS NULL OR reported_currency~'^[A-Z]{3}$'),
  failure_code TEXT CHECK(failure_code IS NULL OR length(failure_code)<=80),
  failure_reason TEXT CHECK(failure_reason IS NULL OR length(failure_reason)<=240),
  result_hash VARCHAR(64) CHECK(result_hash IS NULL OR result_hash~'^[a-f0-9]{64}$'),
  prepared_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(obligation_id,organization_id) REFERENCES investment_refund_obligations(id,organization_id),
  UNIQUE(organization_id,idempotency_key),
  UNIQUE(organization_id,obligation_id,attempt_number),
  UNIQUE(id,organization_id)
);

CREATE OR REPLACE FUNCTION mask_investment_provider_reference(p_reference TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path=public AS $$
  SELECT CASE
    WHEN p_reference IS NULL THEN NULL
    WHEN length(p_reference)<=8 THEN repeat('*',length(p_reference))
    ELSE left(p_reference,4)||repeat('*',GREATEST(length(p_reference)-8,4))||right(p_reference,4)
  END
$$;

CREATE OR REPLACE FUNCTION protect_investment_refund_attempts()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.investment_refund_submission_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Investment refund submission evidence is immutable outside the engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;

CREATE TRIGGER investment_refund_attempts_engine_only
BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_attempts
FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_attempts();

CREATE OR REPLACE FUNCTION begin_investment_refund_submission(
  p_organization UUID,
  p_actor UUID,
  p_obligation UUID,
  p_correlation UUID,
  p_idempotency_key TEXT,
  p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE
  v_obligation investment_refund_obligations;
  v_attempt investment_refund_attempts;
  v_settlement settlements;
  v_request_hash TEXT;
  v_attempt_number INTEGER;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.investments.service_existing permission';
  END IF;
  IF p_obligation IS NULL OR p_correlation IS NULL OR p_at IS NULL
    OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Investment refund submission command is invalid';
  END IF;

  v_request_hash:=encode(digest(convert_to(
    concat_ws('|',p_organization,p_actor,p_obligation,p_correlation,p_idempotency_key),
    'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_organization::TEXT||':investment-refund-submission:'||p_idempotency_key,0));

  SELECT * INTO v_attempt FROM investment_refund_attempts
  WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_attempt.id IS NOT NULL THEN
    IF v_attempt.request_hash<>v_request_hash OR v_attempt.obligation_id<>p_obligation THEN
      RAISE EXCEPTION 'Idempotency key reused with different investment refund submission facts';
    END IF;
    SELECT * INTO v_obligation FROM investment_refund_obligations
    WHERE id=v_attempt.obligation_id AND organization_id=p_organization;
    SELECT * INTO v_settlement FROM settlements
    WHERE id=v_obligation.settlement_id AND organization_id=p_organization;
    RETURN jsonb_build_object(
      'replayed',TRUE,
      'attempt',to_jsonb(v_attempt),
      'obligation',to_jsonb(v_obligation),
      'provider_payment_reference',v_settlement.provider_reference);
  END IF;

  SELECT * INTO v_obligation FROM investment_refund_obligations
  WHERE id=p_obligation AND organization_id=p_organization FOR UPDATE;
  IF v_obligation.id IS NULL THEN RAISE EXCEPTION 'Investment refund obligation was not found'; END IF;
  IF v_obligation.state NOT IN ('created','failed') THEN
    RAISE EXCEPTION 'Investment refund obligation is not eligible for submission';
  END IF;
  IF EXISTS(
    SELECT 1 FROM investment_refund_attempts
    WHERE organization_id=p_organization AND obligation_id=p_obligation
      AND state IN ('prepared','submitted','processing','unknown')
  ) THEN RAISE EXCEPTION 'Investment refund obligation already has an active provider attempt'; END IF;

  SELECT * INTO v_settlement FROM settlements
  WHERE id=v_obligation.settlement_id AND organization_id=p_organization;
  IF v_settlement.id IS NULL OR v_settlement.provider_reference IS NULL
    OR v_settlement.provider_name<>v_obligation.original_provider
    OR v_settlement.provider_environment<>v_obligation.original_environment THEN
    RAISE EXCEPTION 'Original investment refund provider evidence is incomplete';
  END IF;

  SELECT COALESCE(max(attempt_number),0)+1 INTO v_attempt_number
  FROM investment_refund_attempts
  WHERE organization_id=p_organization AND obligation_id=p_obligation;
  PERFORM set_config('microfams.investment_refund_submission_engine','on',TRUE);
  INSERT INTO investment_refund_attempts(
    organization_id,obligation_id,attempt_number,actor_id,correlation_id,
    idempotency_key,request_hash,provider_name,provider_environment,state,
    prepared_at,created_at,updated_at
  ) VALUES(
    p_organization,p_obligation,v_attempt_number,p_actor,p_correlation,
    p_idempotency_key,v_request_hash,v_obligation.original_provider,
    v_obligation.original_environment,'prepared',p_at,p_at,p_at
  ) RETURNING * INTO v_attempt;
  PERFORM set_config('microfams.investment_refund_submission_engine','off',TRUE);

  INSERT INTO organization_audit_log(
    organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at
  ) VALUES(
    p_organization,p_actor,'INVESTMENT_REFUND_SUBMISSION_PREPARED',
    'investment_refund_obligation',p_obligation::TEXT,
    jsonb_build_object('attempt_id',v_attempt.id,'attempt_number',v_attempt_number,
      'provider',v_attempt.provider_name,'environment',v_attempt.provider_environment),
    p_at
  );
  RETURN jsonb_build_object(
    'replayed',FALSE,
    'attempt',to_jsonb(v_attempt),
    'obligation',to_jsonb(v_obligation),
    'provider_payment_reference',v_settlement.provider_reference);
END $$;

CREATE OR REPLACE FUNCTION complete_investment_refund_submission(
  p_organization UUID,
  p_actor UUID,
  p_attempt UUID,
  p_state TEXT,
  p_provider_reported_state TEXT,
  p_provider_reference TEXT,
  p_reported_amount_minor BIGINT,
  p_reported_currency TEXT,
  p_failure_code TEXT,
  p_failure_reason TEXT,
  p_result_hash TEXT,
  p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE v_attempt investment_refund_attempts; v_obligation investment_refund_obligations;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.investments.service_existing permission';
  END IF;
  IF p_state NOT IN ('submitted','processing','unknown','failed','manual_review')
    OR p_result_hash !~ '^[a-f0-9]{64}$' OR p_at IS NULL
    OR (p_provider_reported_state IS NOT NULL
      AND p_provider_reported_state NOT IN ('submitted','processing','succeeded','failed','cancelled')) THEN
    RAISE EXCEPTION 'Investment refund provider result is invalid';
  END IF;
  SELECT * INTO v_attempt FROM investment_refund_attempts
  WHERE id=p_attempt AND organization_id=p_organization FOR UPDATE;
  IF v_attempt.id IS NULL THEN RAISE EXCEPTION 'Investment refund attempt was not found'; END IF;
  SELECT * INTO v_obligation FROM investment_refund_obligations
  WHERE id=v_attempt.obligation_id AND organization_id=p_organization FOR UPDATE;
  IF v_attempt.state<>'prepared' THEN
    IF v_attempt.state<>p_state OR v_attempt.result_hash<>p_result_hash THEN
      RAISE EXCEPTION 'Investment refund attempt result conflicts with existing evidence';
    END IF;
    RETURN jsonb_build_object('attempt',to_jsonb(v_attempt),'obligation',to_jsonb(v_obligation));
  END IF;
  IF p_state<>'manual_review'
    AND NOT (p_state='unknown'
      AND p_reported_amount_minor IS NULL
      AND p_reported_currency IS NULL)
    AND (p_reported_amount_minor IS DISTINCT FROM v_obligation.amount_minor
      OR p_reported_currency IS DISTINCT FROM v_obligation.currency) THEN
    RAISE EXCEPTION 'Investment refund provider money does not match the obligation';
  END IF;

  PERFORM set_config('microfams.investment_refund_submission_engine','on',TRUE);
  PERFORM set_config('microfams.investment_refund_engine','on',TRUE);
  UPDATE investment_refund_attempts SET
    state=p_state,provider_reported_state=p_provider_reported_state,
    provider_reference_hash=CASE WHEN p_provider_reference IS NULL THEN NULL
      ELSE encode(digest(convert_to(p_provider_reference,'UTF8'),'sha256'),'hex') END,
    provider_reference_masked=mask_investment_provider_reference(p_provider_reference),
    reported_amount_minor=p_reported_amount_minor,reported_currency=p_reported_currency,
    failure_code=left(NULLIF(p_failure_code,''),80),
    failure_reason=left(NULLIF(p_failure_reason,''),240),
    result_hash=p_result_hash,completed_at=p_at,updated_at=p_at
  WHERE id=v_attempt.id RETURNING * INTO v_attempt;
  UPDATE investment_refund_obligations SET state=p_state WHERE id=v_obligation.id
  RETURNING * INTO v_obligation;
  PERFORM set_config('microfams.investment_refund_submission_engine','off',TRUE);
  PERFORM set_config('microfams.investment_refund_engine','off',TRUE);

  INSERT INTO organization_audit_log(
    organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at
  ) VALUES(
    p_organization,p_actor,'INVESTMENT_REFUND_SUBMISSION_RECORDED',
    'investment_refund_obligation',v_obligation.id::TEXT,
    jsonb_build_object('attempt_id',v_attempt.id,'attempt_number',v_attempt.attempt_number,
      'state',v_attempt.state,'provider_reported_state',v_attempt.provider_reported_state,
      'provider_reference',v_attempt.provider_reference_masked,'failure_code',v_attempt.failure_code),
    p_at
  );
  RETURN jsonb_build_object('attempt',to_jsonb(v_attempt),'obligation',to_jsonb(v_obligation));
END $$;

ALTER TABLE investment_refund_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_attempts FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_attempts FROM service_role;
GRANT SELECT ON investment_refund_attempts TO service_role;
REVOKE ALL ON FUNCTION mask_investment_provider_reference(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION begin_investment_refund_submission(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION complete_investment_refund_submission(UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION begin_investment_refund_submission(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION complete_investment_refund_submission(UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
