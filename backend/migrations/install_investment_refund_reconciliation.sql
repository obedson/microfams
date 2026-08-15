-- INV-12: append-only investment refund provider reconciliation and durable exceptions.
-- This migration never mutates refund obligations/attempts or posts financial corrections.
SET search_path=public,extensions;

CREATE TABLE investment_refund_reconciliation_runs(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES users(id), provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL CHECK(provider_environment IN('deterministic','sandbox','live')),
  source_hash VARCHAR(64) NOT NULL CHECK(source_hash~'^[a-f0-9]{64}$'),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  period_start TIMESTAMPTZ NOT NULL, period_end TIMESTAMPTZ NOT NULL CHECK(period_end>period_start),
  provider_item_count INTEGER NOT NULL CHECK(provider_item_count>=0),
  matched_count INTEGER NOT NULL CHECK(matched_count>=0), exception_count INTEGER NOT NULL CHECK(exception_count>=0),
  unexplained_variance_minor BIGINT NOT NULL CHECK(unexplained_variance_minor>=0),
  created_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,idempotency_key),
  UNIQUE(organization_id,provider_name,provider_environment,source_hash), UNIQUE(id,organization_id)
);

CREATE TABLE investment_refund_reconciliation_items(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, run_id UUID NOT NULL,
  sequence_number INTEGER NOT NULL CHECK(sequence_number>0), attempt_id UUID, obligation_id UUID,
  classification TEXT NOT NULL CHECK(classification IN(
    'matched','duplicate_provider','missing_local','missing_provider','late_success',
    'amount_mismatch','currency_mismatch','status_mismatch')),
  internal_reference TEXT NOT NULL, provider_reference_hash VARCHAR(64), provider_reference_masked TEXT,
  provider_status TEXT CHECK(provider_status IN('submitted','processing','succeeded','failed','cancelled')),
  provider_amount_minor BIGINT CHECK(provider_amount_minor IS NULL OR provider_amount_minor>0),
  provider_currency VARCHAR(3) CHECK(provider_currency IS NULL OR provider_currency~'^[A-Z]{3}$'),
  local_state TEXT, local_amount_minor BIGINT, local_currency VARCHAR(3), occurred_at TIMESTAMPTZ,
  reason TEXT NOT NULL CHECK(length(reason) BETWEEN 3 AND 240), created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(run_id,organization_id) REFERENCES investment_refund_reconciliation_runs(id,organization_id),
  FOREIGN KEY(attempt_id,organization_id) REFERENCES investment_refund_attempts(id,organization_id),
  FOREIGN KEY(obligation_id,organization_id) REFERENCES investment_refund_obligations(id,organization_id),
  UNIQUE(run_id,sequence_number), UNIQUE(id,organization_id)
);

CREATE TABLE investment_refund_reconciliation_exceptions(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, run_id UUID NOT NULL,
  item_id UUID NOT NULL, classification TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK(state='open'),
  amount_variance_minor BIGINT NOT NULL DEFAULT 0 CHECK(amount_variance_minor>=0),
  created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(run_id,organization_id) REFERENCES investment_refund_reconciliation_runs(id,organization_id),
  FOREIGN KEY(item_id,organization_id) REFERENCES investment_refund_reconciliation_items(id,organization_id),
  UNIQUE(item_id), UNIQUE(id,organization_id)
);

CREATE OR REPLACE FUNCTION protect_investment_refund_reconciliation_evidence()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.investment_refund_reconciliation_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Investment refund reconciliation evidence is immutable outside the engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER investment_refund_reconciliation_runs_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_reconciliation_runs FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_reconciliation_evidence();
CREATE TRIGGER investment_refund_reconciliation_items_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_reconciliation_items FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_reconciliation_evidence();
CREATE TRIGGER investment_refund_reconciliation_exceptions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_reconciliation_exceptions FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_reconciliation_evidence();

CREATE OR REPLACE FUNCTION run_investment_refund_reconciliation(
  p_organization UUID,p_actor UUID,p_provider_name TEXT,p_provider_environment TEXT,
  p_source_hash TEXT,p_idempotency_key TEXT,p_period_start TIMESTAMPTZ,p_period_end TIMESTAMPTZ,
  p_provider_items JSONB,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE
  r investment_refund_reconciliation_runs; i investment_refund_reconciliation_items;
  e JSONB; a investment_refund_attempts; o investment_refund_obligations;
  seq INTEGER:=0; matched INTEGER:=0; exceptions INTEGER:=0; variance BIGINT:=0;
  classification TEXT; reason TEXT; internal_ref TEXT; provider_ref TEXT; provider_status TEXT;
  provider_amount BIGINT; provider_currency TEXT; occurred TIMESTAMPTZ; attempt_uuid UUID;
  reference_hash TEXT; duplicate_count INTEGER; local RECORD;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.investments.service_existing permission';
  END IF;
  IF length(COALESCE(trim(p_provider_name),''))<2 OR p_provider_environment NOT IN('deterministic','sandbox','live')
    OR p_source_hash IS NULL OR p_source_hash!~'^[a-f0-9]{64}$'
    OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160
    OR p_period_start IS NULL OR p_period_end IS NULL OR p_period_end<=p_period_start OR p_at IS NULL
    OR jsonb_typeof(p_provider_items)<>'array' OR jsonb_array_length(p_provider_items)>5000 THEN
    RAISE EXCEPTION 'Investment refund reconciliation command is invalid';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-refund-reconciliation:'||p_idempotency_key,0));
  SELECT * INTO r FROM investment_refund_reconciliation_runs WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF r.id IS NOT NULL THEN
    IF r.source_hash<>p_source_hash OR r.provider_name<>lower(trim(p_provider_name))
      OR r.provider_environment<>p_provider_environment OR r.period_start<>p_period_start OR r.period_end<>p_period_end THEN
      RAISE EXCEPTION 'Idempotency key reused with different investment refund reconciliation facts';
    END IF;
    RETURN jsonb_build_object('run',to_jsonb(r),'items',(SELECT jsonb_agg(to_jsonb(x) ORDER BY sequence_number) FROM investment_refund_reconciliation_items x WHERE x.run_id=r.id),'duplicate',TRUE);
  END IF;
  PERFORM set_config('microfams.investment_refund_reconciliation_engine','on',TRUE);
  INSERT INTO investment_refund_reconciliation_runs(organization_id,actor_id,provider_name,provider_environment,
    source_hash,idempotency_key,period_start,period_end,provider_item_count,matched_count,exception_count,
    unexplained_variance_minor,created_at)
  VALUES(p_organization,p_actor,lower(trim(p_provider_name)),p_provider_environment,p_source_hash,p_idempotency_key,
    p_period_start,p_period_end,jsonb_array_length(p_provider_items),0,0,0,p_at) RETURNING * INTO r;

  FOR e IN SELECT value FROM jsonb_array_elements(p_provider_items) LOOP
    seq:=seq+1; internal_ref:=trim(e->>'internalReference'); provider_ref:=NULLIF(trim(e->>'providerReference'),'');
    provider_status:=e->>'status'; provider_currency:=upper(e->>'currency');
    BEGIN provider_amount:=(e->>'amountMinor')::BIGINT; occurred:=(e->>'occurredAt')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Investment refund provider evidence is invalid'; END;
    IF internal_ref!~*'^investment-refund-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      OR provider_status NOT IN('submitted','processing','succeeded','failed','cancelled')
      OR provider_amount<=0 OR provider_currency!~'^[A-Z]{3}$' OR occurred IS NULL THEN
      RAISE EXCEPTION 'Investment refund provider evidence is invalid';
    END IF;
    attempt_uuid:=replace(internal_ref,'investment-refund-','')::UUID;
    reference_hash:=CASE WHEN provider_ref IS NULL THEN NULL ELSE encode(digest(convert_to(provider_ref,'UTF8'),'sha256'),'hex') END;
    SELECT count(*) INTO duplicate_count FROM investment_refund_reconciliation_items x
      WHERE x.run_id=r.id AND x.internal_reference=internal_ref
        AND x.provider_reference_hash IS NOT DISTINCT FROM reference_hash;
    SELECT * INTO a FROM investment_refund_attempts WHERE id=attempt_uuid AND organization_id=p_organization
      AND provider_name=lower(trim(p_provider_name)) AND provider_environment=p_provider_environment;
    SELECT * INTO o FROM investment_refund_obligations WHERE id=a.obligation_id AND organization_id=p_organization;
    IF duplicate_count>0 THEN classification:='duplicate_provider'; reason:='Provider evidence identity appeared more than once in the source batch.';
    ELSIF a.id IS NULL OR o.id IS NULL THEN classification:='missing_local'; reason:='Provider evidence has no matching local refund attempt.';
    ELSIF a.provider_reference_hash IS DISTINCT FROM reference_hash THEN classification:='status_mismatch'; reason:='Provider refund reference differs from the locally recorded provider attempt.';
    ELSIF provider_amount<>o.amount_minor THEN classification:='amount_mismatch'; reason:='Provider amount differs from the approved refund obligation.';
    ELSIF provider_currency<>o.currency THEN classification:='currency_mismatch'; reason:='Provider currency differs from the approved refund obligation.';
    ELSIF provider_status='succeeded' AND o.state IN('unknown','failed','manual_review') THEN classification:='late_success'; reason:='Provider success arrived after a non-final local timeout or failure state.';
    ELSIF provider_status='succeeded' AND o.state='succeeded' THEN classification:='matched'; reason:='Provider and local verified success evidence match exactly.';
    ELSIF provider_status IN('failed','cancelled') AND o.state='failed' THEN classification:='matched'; reason:='Provider and local failure evidence match.';
    ELSIF provider_status IN('submitted','processing') AND o.state IN('submitted','processing','unknown') THEN classification:='matched'; reason:='Provider and local in-flight evidence are compatible.';
    ELSE classification:='status_mismatch'; reason:='Provider status conflicts with the local refund state.'; END IF;
    INSERT INTO investment_refund_reconciliation_items(organization_id,run_id,sequence_number,attempt_id,obligation_id,
      classification,internal_reference,provider_reference_hash,provider_reference_masked,provider_status,
      provider_amount_minor,provider_currency,local_state,local_amount_minor,local_currency,occurred_at,reason,created_at)
    VALUES(p_organization,r.id,seq,a.id,o.id,classification,internal_ref,reference_hash,
      mask_investment_provider_reference(provider_ref),provider_status,provider_amount,provider_currency,
      o.state,o.amount_minor,o.currency,occurred,reason,p_at) RETURNING * INTO i;
    IF classification='matched' THEN matched:=matched+1; ELSE
      exceptions:=exceptions+1;
      IF classification='amount_mismatch' AND o.id IS NOT NULL THEN variance:=variance+abs(provider_amount-o.amount_minor); END IF;
      INSERT INTO investment_refund_reconciliation_exceptions(organization_id,run_id,item_id,classification,
        amount_variance_minor,created_at)
      VALUES(p_organization,r.id,i.id,classification,
        CASE WHEN classification='amount_mismatch' AND o.id IS NOT NULL THEN abs(provider_amount-o.amount_minor) ELSE 0 END,p_at);
    END IF;
  END LOOP;

  FOR local IN
    SELECT att.*,ob.id AS local_obligation_id,ob.state AS obligation_state,ob.amount_minor,ob.currency
    FROM investment_refund_attempts att JOIN investment_refund_obligations ob
      ON ob.id=att.obligation_id AND ob.organization_id=att.organization_id
    WHERE att.organization_id=p_organization AND att.provider_name=lower(trim(p_provider_name))
      AND att.provider_environment=p_provider_environment AND att.prepared_at>=p_period_start AND att.prepared_at<p_period_end
      AND NOT EXISTS(SELECT 1 FROM investment_refund_reconciliation_items x WHERE x.run_id=r.id AND x.attempt_id=att.id)
  LOOP
    seq:=seq+1; exceptions:=exceptions+1;
    INSERT INTO investment_refund_reconciliation_items(organization_id,run_id,sequence_number,attempt_id,obligation_id,
      classification,internal_reference,local_state,local_amount_minor,local_currency,reason,created_at)
    VALUES(p_organization,r.id,seq,local.id,local.local_obligation_id,'missing_provider',
      'investment-refund-'||local.id::TEXT,local.obligation_state,local.amount_minor,local.currency,
      'Local refund attempt has no provider evidence in the authoritative source batch.',p_at) RETURNING * INTO i;
    INSERT INTO investment_refund_reconciliation_exceptions(organization_id,run_id,item_id,classification,created_at)
    VALUES(p_organization,r.id,i.id,'missing_provider',p_at);
  END LOOP;

  UPDATE investment_refund_reconciliation_runs SET matched_count=matched,exception_count=exceptions,
    unexplained_variance_minor=variance WHERE id=r.id RETURNING * INTO r;
  PERFORM set_config('microfams.investment_refund_reconciliation_engine','off',TRUE);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'INVESTMENT_REFUND_RECONCILIATION_RECORDED','investment_refund_reconciliation_run',r.id::TEXT,
    jsonb_build_object('provider_name',r.provider_name,'provider_environment',r.provider_environment,
      'provider_item_count',r.provider_item_count,'matched_count',matched,'exception_count',exceptions,
      'unexplained_variance_minor',variance,'financial_correction','none'),p_at);
  RETURN jsonb_build_object('run',to_jsonb(r),'items',(SELECT jsonb_agg(to_jsonb(x) ORDER BY sequence_number) FROM investment_refund_reconciliation_items x WHERE x.run_id=r.id),'duplicate',FALSE);
END $$;

ALTER TABLE investment_refund_reconciliation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE investment_refund_reconciliation_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE investment_refund_reconciliation_exceptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_reconciliation_runs,investment_refund_reconciliation_items,investment_refund_reconciliation_exceptions FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_reconciliation_runs,investment_refund_reconciliation_items,investment_refund_reconciliation_exceptions FROM service_role;
GRANT SELECT ON investment_refund_reconciliation_runs,investment_refund_reconciliation_items,investment_refund_reconciliation_exceptions TO service_role;
REVOKE ALL ON FUNCTION run_investment_refund_reconciliation(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,JSONB,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION run_investment_refund_reconciliation(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,JSONB,TIMESTAMPTZ) TO service_role;
