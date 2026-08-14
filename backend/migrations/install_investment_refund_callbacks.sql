-- INV-11: signed, replay-safe provider callbacks for existing investment refund attempts.
SET search_path=public,extensions;

ALTER TABLE investment_refund_attempts
  ADD COLUMN callback_count INTEGER NOT NULL DEFAULT 0 CHECK(callback_count>=0),
  ADD COLUMN last_callback_at TIMESTAMPTZ;

CREATE TABLE investment_refund_callback_events(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  obligation_id UUID NOT NULL,
  attempt_id UUID NOT NULL,
  provider_name TEXT NOT NULL,
  provider_environment TEXT NOT NULL CHECK(provider_environment IN('deterministic','sandbox','live')),
  provider_event_id TEXT,
  event_type TEXT NOT NULL CHECK(length(event_type) BETWEEN 3 AND 120),
  raw_event_hash VARCHAR(64) NOT NULL CHECK(length(raw_event_hash)=64 AND raw_event_hash !~ '[^a-f0-9]'),
  signature_verified BOOLEAN NOT NULL CHECK(signature_verified),
  state TEXT NOT NULL CHECK(state IN('submitted','processing','failed','manual_review','succeeded')),
  provider_reported_state TEXT NOT NULL CHECK(provider_reported_state IN('submitted','processing','succeeded','failed','cancelled')),
  provider_reference_hash VARCHAR(64) CHECK(provider_reference_hash IS NULL OR provider_reference_hash~'^[a-f0-9]{64}$'),
  provider_reference_masked TEXT,
  reported_amount_minor BIGINT NOT NULL CHECK(reported_amount_minor>0),
  reported_currency VARCHAR(3) NOT NULL CHECK(reported_currency~'^[A-Z]{3}$'),
  failure_code TEXT CHECK(failure_code IS NULL OR length(failure_code)<=80),
  failure_reason TEXT CHECK(failure_reason IS NULL OR length(failure_reason)<=240),
  success_journal_id UUID REFERENCES journal_entries(id),
  occurred_at TIMESTAMPTZ,
  received_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(obligation_id,organization_id) REFERENCES investment_refund_obligations(id,organization_id),
  FOREIGN KEY(attempt_id,organization_id) REFERENCES investment_refund_attempts(id,organization_id),
  UNIQUE(provider_name,provider_environment,raw_event_hash),
  UNIQUE(id,organization_id)
);
CREATE UNIQUE INDEX uq_investment_refund_callback_provider_event
  ON investment_refund_callback_events(provider_name,provider_environment,provider_event_id)
  WHERE provider_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION protect_investment_refund_callback_events()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.investment_refund_callback_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Investment refund callback evidence is immutable outside the engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER investment_refund_callback_events_engine_only
BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_callback_events
FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_callback_events();

CREATE OR REPLACE FUNCTION apply_investment_refund_callback(
  p_provider_name TEXT,p_provider_environment TEXT,p_attempt UUID,p_provider_event_id TEXT,
  p_event_type TEXT,p_raw_event_hash TEXT,p_state TEXT,p_provider_reported_state TEXT,
  p_provider_reference TEXT,p_reported_amount_minor BIGINT,p_reported_currency TEXT,
  p_occurred_at TIMESTAMPTZ,p_failure_code TEXT,p_failure_reason TEXT,p_received_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE
  a investment_refund_attempts; o investment_refund_obligations; plan investment_allocation_plans;
  e investment_refund_callback_events; payable financial_accounts; clearing financial_accounts;
  effective_state TEXT:=p_state; code TEXT:=NULLIF(p_failure_code,''); reason TEXT:=NULLIF(p_failure_reason,'');
  journal UUID; ref_hash TEXT; posting_hash TEXT; account_code TEXT; duplicate BOOLEAN:=FALSE;
BEGIN
  IF length(COALESCE(p_provider_name,''))<2 OR p_provider_environment NOT IN('deterministic','sandbox','live')
    OR p_state NOT IN('submitted','processing','failed','succeeded')
    OR p_provider_reported_state NOT IN('submitted','processing','succeeded','failed','cancelled')
    OR p_raw_event_hash IS NULL OR length(p_raw_event_hash)<>64 OR p_raw_event_hash !~ '^[a-f0-9]{64}'
    OR length(COALESCE(p_event_type,'')) NOT BETWEEN 3 AND 120
    OR p_reported_amount_minor IS NULL OR p_reported_amount_minor<=0 OR p_reported_currency IS NULL
    OR upper(p_reported_currency) !~ '^[A-Z]{3}' OR p_received_at IS NULL THEN
    RAISE EXCEPTION 'Investment refund callback is invalid';
  END IF;
  SELECT * INTO e FROM investment_refund_callback_events
    WHERE provider_name=p_provider_name AND provider_environment=p_provider_environment
      AND raw_event_hash=p_raw_event_hash;
  IF e.id IS NOT NULL THEN
    SELECT * INTO o FROM investment_refund_obligations
      WHERE id=e.obligation_id AND organization_id=e.organization_id;
    RETURN jsonb_build_object('event',to_jsonb(e),'obligation',to_jsonb(o),'duplicate',TRUE);
  END IF;
  IF p_provider_event_id IS NOT NULL AND EXISTS(
    SELECT 1 FROM investment_refund_callback_events
    WHERE provider_name=p_provider_name AND provider_environment=p_provider_environment
      AND provider_event_id=p_provider_event_id) THEN
    RAISE EXCEPTION 'Provider refund callback identity was replayed with changed bytes';
  END IF;
  SELECT * INTO a FROM investment_refund_attempts
    WHERE id=p_attempt AND provider_name=p_provider_name AND provider_environment=p_provider_environment FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Investment refund callback attempt was not found'; END IF;
  SELECT * INTO o FROM investment_refund_obligations
    WHERE id=a.obligation_id AND organization_id=a.organization_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Investment refund callback obligation was not found'; END IF;
  ref_hash:=CASE WHEN p_provider_reference IS NULL THEN NULL
    ELSE encode(digest(convert_to(p_provider_reference,'UTF8'),'sha256'),'hex') END;
  IF p_reported_amount_minor IS DISTINCT FROM o.amount_minor
    OR upper(p_reported_currency) IS DISTINCT FROM o.currency THEN
    effective_state:='manual_review'; code:='provider_money_mismatch';
    reason:='The provider callback money did not match the approved refund obligation.';
  END IF;
  IF p_state='succeeded' AND p_provider_reference IS NULL THEN
    effective_state:='manual_review'; code:='provider_reference_missing';
    reason:='The provider success callback did not include a refund reference.';
  END IF;
  IF o.state='succeeded' THEN
    journal:=o.success_journal_id;
    IF effective_state<>'succeeded' THEN
      effective_state:='manual_review'; code:='post_success_callback_conflict';
      reason:='A non-success callback arrived after verified refund success.';
    ELSE
      duplicate:=TRUE;
    END IF;
  ELSE
    IF a.state NOT IN('submitted','processing','unknown','failed','manual_review')
      OR o.state NOT IN('submitted','processing','unknown','failed','manual_review') THEN
      RAISE EXCEPTION 'Investment refund callback is not serviceable';
    END IF;
    IF effective_state='succeeded' THEN
      SELECT * INTO plan FROM investment_allocation_plans
        WHERE id=o.plan_id AND organization_id=o.organization_id;
      SELECT * INTO payable FROM financial_accounts
        WHERE organization_id=o.organization_id AND purpose='investment_refunds_payable'
          AND owner_type='investment_contract' AND owner_id=plan.product_id
          AND currency=o.currency AND effective_until IS NULL;
      IF payable.id IS NULL THEN RAISE EXCEPTION 'Investment refund payable account was not found'; END IF;
      SELECT * INTO clearing FROM financial_accounts
        WHERE organization_id=o.organization_id AND purpose='provider_clearing'
          AND owner_type='provider' AND owner_id=o.settlement_id
          AND currency=o.currency AND effective_until IS NULL;
      IF clearing.id IS NULL THEN
        account_code:='IRF.'||upper(substr(md5(o.settlement_id::TEXT),1,12))||'.CLR';
        INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,
          owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
        VALUES(o.organization_id,account_code,'Investment refund provider clearing','asset','debit',o.currency,
          'provider',o.settlement_id,TRUE,a.actor_id,'provider_clearing',p_received_at::DATE,
          'inv-refund-clearing-'||o.settlement_id::TEXT,
          encode(digest(convert_to(concat_ws('|',o.organization_id,o.settlement_id,'provider_clearing',o.currency),'UTF8'),'sha256'),'hex'))
        RETURNING * INTO clearing;
      END IF;
      posting_hash:=encode(digest(convert_to(concat_ws('|',o.organization_id,o.id,a.id,ref_hash,
        o.amount_minor,payable.id,clearing.id),'UTF8'),'sha256'),'hex');
      journal:=post_financial_journal(o.organization_id,o.currency,p_received_at::DATE,
        'investment.refund_success',o.id::TEXT,'inv-refund-success-'||o.id::TEXT,posting_hash,
        a.correlation_id,'Post verified investment refund success',a.actor_id,jsonb_build_array(
          jsonb_build_object('account_id',payable.id,'line_number',1,'side','debit',
            'amount_minor',o.amount_minor,'memo','Settle investment refund payable'),
          jsonb_build_object('account_id',clearing.id,'line_number',2,'side','credit',
            'amount_minor',o.amount_minor,'memo','Record provider refund cash movement')));
    END IF;
    PERFORM set_config('microfams.investment_refund_submission_engine','on',TRUE);
    PERFORM set_config('microfams.investment_refund_engine','on',TRUE);
    UPDATE investment_refund_attempts SET state=effective_state,
      provider_reported_state=p_provider_reported_state,
      provider_reference_hash=COALESCE(ref_hash,provider_reference_hash),
      provider_reference_masked=COALESCE(mask_investment_provider_reference(p_provider_reference),provider_reference_masked),
      reported_amount_minor=p_reported_amount_minor,reported_currency=upper(p_reported_currency),
      failure_code=left(code,80),failure_reason=left(reason,240),
      callback_count=callback_count+1,last_callback_at=p_received_at,updated_at=p_received_at
      WHERE id=a.id RETURNING * INTO a;
    UPDATE investment_refund_obligations SET state=effective_state,
      success_journal_id=CASE WHEN effective_state='succeeded' THEN journal ELSE NULL END,
      succeeded_at=CASE WHEN effective_state='succeeded' THEN p_received_at ELSE NULL END
      WHERE id=o.id RETURNING * INTO o;
    PERFORM set_config('microfams.investment_refund_submission_engine','off',TRUE);
    PERFORM set_config('microfams.investment_refund_engine','off',TRUE);
  END IF;
  PERFORM set_config('microfams.investment_refund_callback_engine','on',TRUE);
  INSERT INTO investment_refund_callback_events(organization_id,obligation_id,attempt_id,provider_name,
    provider_environment,provider_event_id,event_type,raw_event_hash,signature_verified,state,provider_reported_state,
    provider_reference_hash,provider_reference_masked,reported_amount_minor,reported_currency,
    failure_code,failure_reason,success_journal_id,occurred_at,received_at)
  VALUES(o.organization_id,o.id,a.id,p_provider_name,p_provider_environment,NULLIF(p_provider_event_id,''),
    p_event_type,p_raw_event_hash,TRUE,effective_state,p_provider_reported_state,ref_hash,
    mask_investment_provider_reference(p_provider_reference),p_reported_amount_minor,upper(p_reported_currency),
    left(code,80),left(reason,240),journal,p_occurred_at,p_received_at) RETURNING * INTO e;
  PERFORM set_config('microfams.investment_refund_callback_engine','off',TRUE);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(o.organization_id,NULL,'INVESTMENT_REFUND_CALLBACK_RECORDED','investment_refund_obligation',o.id::TEXT,
    jsonb_build_object('attempt_id',a.id,'event_id',e.id,'state',effective_state,
      'provider_reported_state',p_provider_reported_state,
      'provider_reference',mask_investment_provider_reference(p_provider_reference),
      'success_journal_id',journal),p_received_at);
  RETURN jsonb_build_object('event',to_jsonb(e),'obligation',to_jsonb(o),'duplicate',duplicate);
END $$;

ALTER TABLE investment_refund_callback_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_callback_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_callback_events FROM service_role;
GRANT SELECT ON investment_refund_callback_events TO service_role;
REVOKE ALL ON FUNCTION apply_investment_refund_callback(TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,TIMESTAMPTZ,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_investment_refund_callback(TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,TIMESTAMPTZ,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
