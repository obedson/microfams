-- INV-10: recover provider refund attempts and post verified success exactly once.
SET search_path=public,extensions;

ALTER TABLE investment_refund_attempts DROP CONSTRAINT investment_refund_attempts_state_check;
ALTER TABLE investment_refund_attempts ADD CONSTRAINT investment_refund_attempts_state_check
  CHECK(state IN ('prepared','submitted','processing','unknown','failed','manual_review','succeeded'));
ALTER TABLE investment_refund_attempts
  ADD COLUMN recovery_count INTEGER NOT NULL DEFAULT 0 CHECK(recovery_count>=0),
  ADD COLUMN last_recovered_at TIMESTAMPTZ;
ALTER TABLE investment_refund_obligations
  ADD COLUMN success_journal_id UUID UNIQUE REFERENCES journal_entries(id),
  ADD COLUMN succeeded_at TIMESTAMPTZ;
ALTER TABLE investment_refund_obligations ADD CONSTRAINT investment_refund_success_evidence
  CHECK((state='succeeded' AND success_journal_id IS NOT NULL AND succeeded_at IS NOT NULL)
    OR (state<>'succeeded' AND success_journal_id IS NULL AND succeeded_at IS NULL));

CREATE TABLE investment_refund_recovery_events(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL,
  obligation_id UUID NOT NULL, attempt_id UUID NOT NULL, actor_id UUID NOT NULL REFERENCES users(id),
  state TEXT NOT NULL CHECK(state IN('processing','unknown','failed','manual_review','succeeded')),
  provider_reported_state TEXT CHECK(provider_reported_state IN('submitted','processing','succeeded','failed','cancelled')),
  provider_reference_hash VARCHAR(64) CHECK(provider_reference_hash IS NULL OR provider_reference_hash~'^[a-f0-9]{64}$'),
  provider_reference_masked TEXT, reported_amount_minor BIGINT CHECK(reported_amount_minor IS NULL OR reported_amount_minor>0),
  reported_currency VARCHAR(3) CHECK(reported_currency IS NULL OR reported_currency~'^[A-Z]{3}$'),
  failure_code TEXT CHECK(failure_code IS NULL OR length(failure_code)<=80),
  failure_reason TEXT CHECK(failure_reason IS NULL OR length(failure_reason)<=240),
  result_hash VARCHAR(64) NOT NULL CHECK(result_hash~'^[a-f0-9]{64}$'),
  success_journal_id UUID REFERENCES journal_entries(id), occurred_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(obligation_id,organization_id) REFERENCES investment_refund_obligations(id,organization_id),
  FOREIGN KEY(attempt_id,organization_id) REFERENCES investment_refund_attempts(id,organization_id),
  UNIQUE(organization_id,attempt_id,result_hash), UNIQUE(id,organization_id));
CREATE UNIQUE INDEX uq_investment_refund_recovery_success
  ON investment_refund_recovery_events(organization_id,obligation_id) WHERE state='succeeded';

CREATE OR REPLACE FUNCTION protect_investment_refund_recovery_events()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.investment_refund_recovery_engine',TRUE)<>'on' THEN
    RAISE EXCEPTION 'Investment refund recovery evidence is immutable outside the engine';
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER investment_refund_recovery_events_engine_only
BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_recovery_events
FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_recovery_events();

CREATE OR REPLACE FUNCTION prepare_investment_refund_recovery(
  p_organization UUID,p_actor UUID,p_obligation UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o investment_refund_obligations; a investment_refund_attempts; s settlements;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.investments.service_existing permission';
  END IF;
  SELECT * INTO o FROM investment_refund_obligations
    WHERE id=p_obligation AND organization_id=p_organization FOR UPDATE;
  IF o.id IS NULL OR o.state NOT IN('submitted','processing','unknown') THEN
    RAISE EXCEPTION 'Investment refund obligation is not eligible for recovery';
  END IF;
  SELECT * INTO a FROM investment_refund_attempts
    WHERE organization_id=p_organization AND obligation_id=p_obligation
      AND state IN('submitted','processing','unknown')
    ORDER BY attempt_number DESC LIMIT 1 FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Active investment refund attempt was not found'; END IF;
  SELECT * INTO s FROM settlements WHERE id=o.settlement_id AND organization_id=p_organization;
  IF s.id IS NULL OR s.provider_reference IS NULL OR s.provider_name<>a.provider_name
    OR s.provider_environment<>a.provider_environment THEN
    RAISE EXCEPTION 'Original investment refund provider evidence is incomplete';
  END IF;
  RETURN jsonb_build_object('attempt',to_jsonb(a),'obligation',to_jsonb(o),
    'provider_payment_reference',s.provider_reference);
END $$;

CREATE OR REPLACE FUNCTION complete_investment_refund_recovery(
  p_organization UUID,p_actor UUID,p_attempt UUID,p_state TEXT,p_provider_reported_state TEXT,
  p_provider_reference TEXT,p_reported_amount_minor BIGINT,p_reported_currency TEXT,
  p_failure_code TEXT,p_failure_reason TEXT,p_result_hash TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE
  a investment_refund_attempts; o investment_refund_obligations; p investment_allocation_plans;
  e investment_refund_recovery_events; payable financial_accounts; clearing financial_accounts;
  journal UUID; h TEXT; ref_hash TEXT; code TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN
    RAISE EXCEPTION 'Missing financial.investments.service_existing permission';
  END IF;
  IF p_state NOT IN('processing','unknown','failed','manual_review','succeeded')
    OR p_result_hash!~'^[a-f0-9]{64}$' OR p_at IS NULL THEN
    RAISE EXCEPTION 'Investment refund recovery result is invalid';
  END IF;
  SELECT * INTO a FROM investment_refund_attempts
    WHERE id=p_attempt AND organization_id=p_organization FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Investment refund attempt was not found'; END IF;
  SELECT * INTO o FROM investment_refund_obligations
    WHERE id=a.obligation_id AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO e FROM investment_refund_recovery_events
    WHERE organization_id=p_organization AND attempt_id=p_attempt AND result_hash=p_result_hash;
  IF e.id IS NOT NULL THEN
    RETURN jsonb_build_object('event',to_jsonb(e),'attempt',to_jsonb(a),'obligation',to_jsonb(o));
  END IF;
  IF a.state='succeeded' OR o.state='succeeded' THEN RAISE EXCEPTION 'Investment refund success is already final'; END IF;
  IF a.state NOT IN('submitted','processing','unknown') OR o.state NOT IN('submitted','processing','unknown') THEN
    RAISE EXCEPTION 'Investment refund attempt is not recoverable';
  END IF;
  IF p_state='succeeded' AND (p_provider_reported_state<>'succeeded' OR p_provider_reference IS NULL
    OR p_reported_amount_minor IS DISTINCT FROM o.amount_minor
    OR upper(p_reported_currency) IS DISTINCT FROM o.currency) THEN
    RAISE EXCEPTION 'Verified investment refund success money is invalid';
  END IF;
  IF p_state NOT IN('unknown','manual_review') AND
    (p_reported_amount_minor IS DISTINCT FROM o.amount_minor
      OR upper(p_reported_currency) IS DISTINCT FROM o.currency) THEN
    RAISE EXCEPTION 'Investment refund recovery money does not match the obligation';
  END IF;
  ref_hash:=CASE WHEN p_provider_reference IS NULL THEN NULL
    ELSE encode(digest(convert_to(p_provider_reference,'UTF8'),'sha256'),'hex') END;
  IF p_state='succeeded' THEN
    SELECT * INTO p FROM investment_allocation_plans WHERE id=o.plan_id AND organization_id=p_organization;
    SELECT * INTO payable FROM financial_accounts
      WHERE organization_id=p_organization AND purpose='investment_refunds_payable'
        AND owner_type='investment_contract' AND owner_id=p.product_id
        AND currency=o.currency AND effective_until IS NULL;
    IF payable.id IS NULL THEN RAISE EXCEPTION 'Investment refund payable account was not found'; END IF;
    SELECT * INTO clearing FROM financial_accounts
      WHERE organization_id=p_organization AND purpose='provider_clearing'
        AND owner_type='provider' AND owner_id=o.settlement_id
        AND currency=o.currency AND effective_until IS NULL;
    IF clearing.id IS NULL THEN
      code:='IRF.'||upper(substr(md5(o.settlement_id::TEXT),1,12))||'.CLR';
      INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,
        owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
      VALUES(p_organization,code,'Investment refund provider clearing','asset','debit',o.currency,
        'provider',o.settlement_id,TRUE,p_actor,'provider_clearing',p_at::DATE,
        'inv-refund-clearing-'||o.settlement_id::TEXT,
        encode(digest(convert_to(concat_ws('|',p_organization,o.settlement_id,'provider_clearing',o.currency),'UTF8'),'sha256'),'hex'))
      RETURNING * INTO clearing;
    END IF;
    h:=encode(digest(convert_to(concat_ws('|',p_organization,o.id,p_attempt,ref_hash,o.amount_minor,
      payable.id,clearing.id),'UTF8'),'sha256'),'hex');
    journal:=post_financial_journal(p_organization,o.currency,p_at::DATE,'investment.refund_success',
      o.id::TEXT,'inv-refund-success-'||o.id::TEXT,h,a.correlation_id,
      'Post verified investment refund success',p_actor,jsonb_build_array(
        jsonb_build_object('account_id',payable.id,'line_number',1,'side','debit',
          'amount_minor',o.amount_minor,'memo','Settle investment refund payable'),
        jsonb_build_object('account_id',clearing.id,'line_number',2,'side','credit',
          'amount_minor',o.amount_minor,'memo','Record provider refund cash movement')));
  END IF;
  PERFORM set_config('microfams.investment_refund_recovery_engine','on',TRUE);
  PERFORM set_config('microfams.investment_refund_submission_engine','on',TRUE);
  PERFORM set_config('microfams.investment_refund_engine','on',TRUE);
  UPDATE investment_refund_attempts SET state=p_state,provider_reported_state=p_provider_reported_state,
    provider_reference_hash=COALESCE(ref_hash,provider_reference_hash),
    provider_reference_masked=COALESCE(mask_investment_provider_reference(p_provider_reference),provider_reference_masked),
    reported_amount_minor=COALESCE(p_reported_amount_minor,reported_amount_minor),
    reported_currency=COALESCE(upper(p_reported_currency),reported_currency),
    failure_code=left(NULLIF(p_failure_code,''),80),failure_reason=left(NULLIF(p_failure_reason,''),240),
    result_hash=p_result_hash,recovery_count=recovery_count+1,last_recovered_at=p_at,updated_at=p_at
    WHERE id=a.id RETURNING * INTO a;
  UPDATE investment_refund_obligations SET state=p_state,
    success_journal_id=CASE WHEN p_state='succeeded' THEN journal ELSE NULL END,
    succeeded_at=CASE WHEN p_state='succeeded' THEN p_at ELSE NULL END
    WHERE id=o.id RETURNING * INTO o;
  INSERT INTO investment_refund_recovery_events(organization_id,obligation_id,attempt_id,actor_id,state,
    provider_reported_state,provider_reference_hash,provider_reference_masked,reported_amount_minor,
    reported_currency,failure_code,failure_reason,result_hash,success_journal_id,occurred_at,created_at)
  VALUES(p_organization,o.id,a.id,p_actor,p_state,p_provider_reported_state,ref_hash,
    mask_investment_provider_reference(p_provider_reference),p_reported_amount_minor,upper(p_reported_currency),
    left(NULLIF(p_failure_code,''),80),left(NULLIF(p_failure_reason,''),240),p_result_hash,journal,p_at,p_at)
  RETURNING * INTO e;
  PERFORM set_config('microfams.investment_refund_recovery_engine','off',TRUE);
  PERFORM set_config('microfams.investment_refund_submission_engine','off',TRUE);
  PERFORM set_config('microfams.investment_refund_engine','off',TRUE);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'INVESTMENT_REFUND_RECOVERY_RECORDED','investment_refund_obligation',o.id::TEXT,
    jsonb_build_object('attempt_id',a.id,'state',p_state,'provider_reported_state',p_provider_reported_state,
      'provider_reference',mask_investment_provider_reference(p_provider_reference),'success_journal_id',journal),p_at);
  RETURN jsonb_build_object('event',to_jsonb(e),'attempt',to_jsonb(a),'obligation',to_jsonb(o));
END $$;

ALTER TABLE investment_refund_recovery_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_recovery_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_recovery_events FROM service_role;
GRANT SELECT ON investment_refund_recovery_events TO service_role;
REVOKE ALL ON FUNCTION prepare_investment_refund_recovery(UUID,UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION complete_investment_refund_recovery(UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION prepare_investment_refund_recovery(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION complete_investment_refund_recovery(UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
