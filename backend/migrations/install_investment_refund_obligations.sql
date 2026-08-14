-- INV-07: recognize settlement-linked refund obligations and reclassify liabilities; no provider submission or unit execution.
SET search_path=public,extensions;

INSERT INTO financial_account_purpose_rules(purpose,account_class,normal_side,allowed_owner_types,is_control)
VALUES('investment_refunds_payable','liability','credit',ARRAY['investment_contract'],TRUE);

CREATE TABLE investment_refund_recognition_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, plan_id UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
  obligation_count INTEGER NOT NULL CHECK(obligation_count>0), total_amount_minor BIGINT NOT NULL CHECK(total_amount_minor>0),
  recognized_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(plan_id,organization_id) REFERENCES investment_allocation_plans(id,organization_id),
  UNIQUE(organization_id,plan_id), UNIQUE(organization_id,idempotency_key), UNIQUE(id,organization_id)
);
CREATE TABLE investment_refund_obligations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, recognition_run_id UUID NOT NULL,
  plan_id UUID NOT NULL, plan_item_id UUID NOT NULL REFERENCES investment_allocation_plan_items(id),
  subscription_id UUID NOT NULL, settlement_id UUID NOT NULL REFERENCES settlements(id), investor_id UUID NOT NULL REFERENCES users(id),
  amount_minor BIGINT NOT NULL CHECK(amount_minor>0), currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  original_provider TEXT NOT NULL, original_environment TEXT NOT NULL CHECK(original_environment IN ('deterministic','sandbox','live')),
  state TEXT NOT NULL DEFAULT 'created' CHECK(state IN ('created','submitted','processing','unknown','succeeded','failed','manual_review','reversed')),
  recognition_journal_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id), created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(recognition_run_id,organization_id) REFERENCES investment_refund_recognition_runs(id,organization_id),
  FOREIGN KEY(plan_id,organization_id) REFERENCES investment_allocation_plans(id,organization_id),
  FOREIGN KEY(subscription_id,organization_id) REFERENCES investment_subscription_intents(id,organization_id),
  UNIQUE(organization_id,plan_item_id), UNIQUE(id,organization_id)
);

CREATE OR REPLACE FUNCTION protect_investment_refund_recognition() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_refund_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment refund recognition evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_refund_runs_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_recognition_runs FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_recognition();
CREATE TRIGGER investment_refund_obligations_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_obligations FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_recognition();

CREATE OR REPLACE FUNCTION recognize_investment_refund_obligations(p_organization UUID,p_actor UUID,p_plan UUID,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE plan investment_allocation_plans; run investment_refund_recognition_runs; item RECORD;
  subscriptions_account financial_accounts; refunds_account financial_accounts; h TEXT; journal_hash TEXT; journal_id UUID; item_count INTEGER; item_total BIGINT; plan_currency TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_plan IS NULL OR p_correlation IS NULL OR p_at IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment refund recognition command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_plan,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-refund-recognition:'||p_idempotency_key,0));
 SELECT * INTO run FROM investment_refund_recognition_runs WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF run.id IS NOT NULL THEN
   IF run.request_hash<>h OR run.plan_id<>p_plan THEN RAISE EXCEPTION 'Idempotency key reused with different investment refund facts'; END IF;
   RETURN jsonb_build_object('run',to_jsonb(run),'obligations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at,o.id) FROM investment_refund_obligations o WHERE o.recognition_run_id=run.id));
 END IF;
 SELECT * INTO plan FROM investment_allocation_plans WHERE id=p_plan AND organization_id=p_organization FOR UPDATE;
 SELECT currency INTO plan_currency FROM investment_products WHERE id=plan.product_id AND organization_id=p_organization;
 IF plan.id IS NULL OR plan.state<>'approved' OR plan.refund_due_minor<=0 OR plan_currency IS NULL THEN RAISE EXCEPTION 'Investment allocation plan is not eligible for refund recognition'; END IF;
 IF EXISTS(SELECT 1 FROM investment_refund_recognition_runs r WHERE r.organization_id=p_organization AND r.plan_id=plan.id) THEN RAISE EXCEPTION 'Investment refund obligations have already been recognized for this plan'; END IF;
 SELECT count(*),COALESCE(sum(i.refund_due_minor),0) INTO item_count,item_total FROM investment_allocation_plan_items i WHERE i.organization_id=p_organization AND i.plan_id=plan.id AND i.refund_due_minor>0;
 IF item_count<=0 OR item_total<>plan.refund_due_minor THEN RAISE EXCEPTION 'Approved investment refund totals are inconsistent'; END IF;
 IF (SELECT count(*) FROM investment_allocation_plan_items i
   JOIN investment_subscription_intents si ON si.id=i.subscription_id AND si.organization_id=i.organization_id
   JOIN investment_subscription_settlements iss ON iss.subscription_id=si.id AND iss.organization_id=si.organization_id AND iss.settlement_id=i.settlement_id
   JOIN settlements s ON s.id=i.settlement_id AND s.organization_id=i.organization_id
   JOIN journal_entries j ON j.id=s.journal_entry_id AND j.organization_id=s.organization_id AND j.status='posted'
   WHERE i.organization_id=p_organization AND i.plan_id=plan.id AND i.refund_due_minor>0
     AND si.state='settled' AND s.state IN ('posted','reconciled') AND s.currency=si.currency AND iss.amount_minor=si.requested_amount_minor)<>item_count THEN RAISE EXCEPTION 'Investment refund settlement evidence is incomplete or ineligible'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-refund-accounts:'||plan.product_id::TEXT||':'||plan_currency,0));
 SELECT * INTO subscriptions_account FROM financial_accounts WHERE organization_id=p_organization AND purpose='investor_subscriptions_payable' AND owner_type='investment_contract' AND owner_id=plan.product_id AND currency=plan_currency AND effective_until IS NULL;
 IF subscriptions_account.id IS NULL THEN
   INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
   VALUES(p_organization,'INV.'||upper(substr(plan.product_id::TEXT,1,12))||'.SUB','Investment subscriptions payable','liability','credit',plan_currency,'investment_contract',plan.product_id,TRUE,p_actor,'investor_subscriptions_payable',p_at::DATE,'inv-subscriptions-'||plan.product_id::TEXT,
     encode(digest(convert_to(p_organization::TEXT||'|'||plan.product_id::TEXT||'|investor_subscriptions_payable|'||plan_currency,'UTF8'),'sha256'),'hex')) RETURNING * INTO subscriptions_account;
   INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'FINANCIAL_ACCOUNT_PROVISIONED','financial_account',subscriptions_account.id::TEXT,jsonb_build_object('purpose',subscriptions_account.purpose,'owner_id',plan.product_id),p_at);
 END IF;
 SELECT * INTO refunds_account FROM financial_accounts WHERE organization_id=p_organization AND purpose='investment_refunds_payable' AND owner_type='investment_contract' AND owner_id=plan.product_id AND currency=plan_currency AND effective_until IS NULL;
 IF refunds_account.id IS NULL THEN
   INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
   VALUES(p_organization,'INV.'||upper(substr(plan.product_id::TEXT,1,12))||'.REF','Investment refunds payable','liability','credit',plan_currency,'investment_contract',plan.product_id,TRUE,p_actor,'investment_refunds_payable',p_at::DATE,'inv-refunds-'||plan.product_id::TEXT,
     encode(digest(convert_to(p_organization::TEXT||'|'||plan.product_id::TEXT||'|investment_refunds_payable|'||plan_currency,'UTF8'),'sha256'),'hex')) RETURNING * INTO refunds_account;
   INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'FINANCIAL_ACCOUNT_PROVISIONED','financial_account',refunds_account.id::TEXT,jsonb_build_object('purpose',refunds_account.purpose,'owner_id',plan.product_id),p_at);
 END IF;
 PERFORM set_config('microfams.investment_refund_engine','on',TRUE);
 INSERT INTO investment_refund_recognition_runs(organization_id,plan_id,actor_id,idempotency_key,request_hash,correlation_id,obligation_count,total_amount_minor,recognized_at,created_at)
 VALUES(p_organization,plan.id,p_actor,p_idempotency_key,h,p_correlation,item_count,item_total,p_at,p_at) RETURNING * INTO run;
 FOR item IN
   SELECT i.*,si.investor_id,si.currency,s.provider_name,s.provider_environment
   FROM investment_allocation_plan_items i JOIN investment_subscription_intents si ON si.id=i.subscription_id AND si.organization_id=i.organization_id
   JOIN settlements s ON s.id=i.settlement_id AND s.organization_id=i.organization_id
   WHERE i.organization_id=p_organization AND i.plan_id=plan.id AND i.refund_due_minor>0 ORDER BY i.allocation_rank
 LOOP
   journal_hash:=encode(digest(convert_to(concat_ws('|',p_organization,run.id,item.id,item.refund_due_minor,item.currency,subscriptions_account.id,refunds_account.id),'UTF8'),'sha256'),'hex');
   journal_id:=post_financial_journal(p_organization,item.currency,p_at::DATE,'investment.refund_obligation',item.id::TEXT,'inv-refund-journal-'||item.id::TEXT,journal_hash,p_correlation,'Recognize investment oversubscription refund',p_actor,
     jsonb_build_array(
       jsonb_build_object('account_id',subscriptions_account.id,'line_number',1,'side','debit','amount_minor',item.refund_due_minor,'memo','Reclassify unallocated subscription'),
       jsonb_build_object('account_id',refunds_account.id,'line_number',2,'side','credit','amount_minor',item.refund_due_minor,'memo','Recognize investor refund payable')
     ));
   INSERT INTO investment_refund_obligations(organization_id,recognition_run_id,plan_id,plan_item_id,subscription_id,settlement_id,investor_id,amount_minor,currency,original_provider,original_environment,state,recognition_journal_id,created_at)
   VALUES(p_organization,run.id,plan.id,item.id,item.subscription_id,item.settlement_id,item.investor_id,item.refund_due_minor,item.currency,item.provider_name,item.provider_environment,'created',journal_id,p_at);
 END LOOP;
 PERFORM set_config('microfams.investment_refund_engine','off',TRUE);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'INVESTMENT_REFUND_OBLIGATIONS_RECOGNIZED','investment_allocation_plan',plan.id::TEXT,jsonb_build_object('recognition_run_id',run.id,'obligation_count',item_count,'total_amount_minor',item_total,'provider_submission','disabled','unit_execution','disabled'),p_at);
 RETURN jsonb_build_object('run',to_jsonb(run),'obligations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at,o.id) FROM investment_refund_obligations o WHERE o.recognition_run_id=run.id));
END $$;

ALTER TABLE investment_refund_recognition_runs ENABLE ROW LEVEL SECURITY; ALTER TABLE investment_refund_obligations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_recognition_runs,investment_refund_obligations FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_recognition_runs,investment_refund_obligations FROM service_role;
GRANT SELECT ON investment_refund_recognition_runs,investment_refund_obligations TO service_role;
REVOKE ALL ON FUNCTION recognize_investment_refund_obligations(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION recognize_investment_refund_obligations(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
