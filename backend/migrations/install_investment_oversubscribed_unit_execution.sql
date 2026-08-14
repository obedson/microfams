-- INV-08: issue approved oversubscribed units only after refund obligations are recognized; no provider submission.
SET search_path=public,extensions;

CREATE TABLE investment_allocation_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, plan_id UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
  subscription_count INTEGER NOT NULL CHECK(subscription_count>0), unit_count BIGINT NOT NULL CHECK(unit_count>0),
  allocated_principal_minor BIGINT NOT NULL CHECK(allocated_principal_minor>0), executed_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(plan_id,organization_id) REFERENCES investment_allocation_plans(id,organization_id),
  UNIQUE(organization_id,plan_id), UNIQUE(organization_id,idempotency_key), UNIQUE(id,organization_id)
);

CREATE OR REPLACE FUNCTION protect_investment_allocation_execution() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_allocation_execution_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment allocation execution evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_allocation_executions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_allocation_executions FOR EACH ROW EXECUTE FUNCTION protect_investment_allocation_execution();

CREATE OR REPLACE FUNCTION execute_investment_allocation_plan(p_organization UUID,p_actor UUID,p_plan UUID,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE plan investment_allocation_plans; version investment_product_versions; execution investment_allocation_executions; item RECORD;
  h TEXT; unit_hash TEXT; expected_subscriptions INTEGER; expected_units BIGINT; expected_principal BIGINT; refund_items INTEGER; recognized_items INTEGER;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_plan IS NULL OR p_correlation IS NULL OR p_at IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment allocation execution command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_plan,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-allocation-execution:'||p_idempotency_key,0));
 SELECT * INTO execution FROM investment_allocation_executions WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF execution.id IS NOT NULL THEN
   IF execution.request_hash<>h OR execution.plan_id<>p_plan THEN RAISE EXCEPTION 'Idempotency key reused with different investment allocation execution facts'; END IF;
   RETURN jsonb_build_object('execution',to_jsonb(execution),'units',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.allocated_at,u.id) FROM investment_units u JOIN investment_allocation_plan_items i ON i.subscription_id=u.subscription_id AND i.organization_id=u.organization_id WHERE i.plan_id=execution.plan_id));
 END IF;
 SELECT * INTO plan FROM investment_allocation_plans WHERE id=p_plan AND organization_id=p_organization FOR UPDATE;
 IF plan.id IS NULL OR plan.state<>'approved' OR plan.allocated_units<>plan.available_units OR plan.total_settled_minor<>plan.allocated_principal_minor+plan.refund_due_minor THEN RAISE EXCEPTION 'Investment allocation plan is not eligible for execution'; END IF;
 SELECT * INTO version FROM investment_product_versions WHERE id=plan.product_version_id AND organization_id=p_organization FOR SHARE;
 IF version.id IS NULL OR version.state<>'approved' OR version.unit_method<>'fixed_unit_price' OR version.unit_price_minor IS NULL THEN RAISE EXCEPTION 'Investment product version is not eligible for allocation execution'; END IF;
 IF EXISTS(SELECT 1 FROM investment_allocation_executions e WHERE e.organization_id=p_organization AND e.plan_id=plan.id) THEN RAISE EXCEPTION 'Investment allocation plan has already been executed'; END IF;
 SELECT count(*) FILTER(WHERE allocated_units>0),COALESCE(sum(allocated_units),0),COALESCE(sum(allocated_principal_minor),0),count(*) FILTER(WHERE refund_due_minor>0)
 INTO expected_subscriptions,expected_units,expected_principal,refund_items FROM investment_allocation_plan_items WHERE organization_id=p_organization AND plan_id=plan.id;
 IF expected_subscriptions<=0 OR expected_units<>plan.allocated_units OR expected_principal<>plan.allocated_principal_minor THEN RAISE EXCEPTION 'Approved investment allocation totals are inconsistent'; END IF;
 SELECT count(*) INTO recognized_items FROM investment_allocation_plan_items i
 JOIN investment_refund_obligations o ON o.organization_id=i.organization_id AND o.plan_item_id=i.id AND o.plan_id=i.plan_id AND o.amount_minor=i.refund_due_minor
 JOIN journal_entries j ON j.id=o.recognition_journal_id AND j.organization_id=o.organization_id AND j.status='posted'
 WHERE i.organization_id=p_organization AND i.plan_id=plan.id AND i.refund_due_minor>0;
 IF recognized_items<>refund_items OR (SELECT COALESCE(sum(o.amount_minor),0) FROM investment_refund_obligations o WHERE o.organization_id=p_organization AND o.plan_id=plan.id)<>plan.refund_due_minor THEN RAISE EXCEPTION 'Every investment refund obligation and recognition journal is required before unit execution'; END IF;
 IF EXISTS(SELECT 1 FROM investment_allocation_plan_items i JOIN investment_subscription_intents s ON s.id=i.subscription_id AND s.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.plan_id=plan.id AND i.allocated_units>0 AND s.state<>'settled') THEN RAISE EXCEPTION 'Investment subscriptions are not eligible for oversubscribed unit execution'; END IF;
 IF EXISTS(SELECT 1 FROM investment_allocation_plan_items i JOIN investment_units u ON u.subscription_id=i.subscription_id AND u.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.plan_id=plan.id) THEN RAISE EXCEPTION 'Investment units already exist for this allocation plan'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-product-allocation:'||plan.product_id::TEXT,0));
 PERFORM set_config('microfams.investment_allocation_execution_engine','on',TRUE); PERFORM set_config('microfams.investment_unit_engine','on',TRUE); PERFORM set_config('microfams.investment_subscription_engine','on',TRUE);
 INSERT INTO investment_allocation_executions(organization_id,plan_id,actor_id,idempotency_key,request_hash,correlation_id,subscription_count,unit_count,allocated_principal_minor,executed_at,created_at)
 VALUES(p_organization,plan.id,p_actor,p_idempotency_key,h,p_correlation,expected_subscriptions,expected_units,expected_principal,p_at,p_at) RETURNING * INTO execution;
 FOR item IN SELECT * FROM investment_allocation_plan_items WHERE organization_id=p_organization AND plan_id=plan.id AND allocated_units>0 ORDER BY allocation_rank LOOP
   unit_hash:=encode(digest(convert_to(concat_ws('|',p_organization,execution.id,item.id,item.subscription_id,item.allocated_units,version.unit_price_minor,item.allocated_principal_minor),'UTF8'),'sha256'),'hex');
   INSERT INTO investment_units(organization_id,product_id,product_version_id,subscription_id,investor_id,unit_count,unit_price_minor,allocated_amount_minor,currency,idempotency_key,request_hash,correlation_id,allocated_at,created_at)
   SELECT p_organization,plan.product_id,plan.product_version_id,item.subscription_id,s.investor_id,item.allocated_units,version.unit_price_minor,item.allocated_principal_minor,s.currency,'inv-plan-unit-'||item.id::TEXT,unit_hash,p_correlation,p_at,p_at
   FROM investment_subscription_intents s WHERE s.id=item.subscription_id AND s.organization_id=p_organization;
   UPDATE investment_subscription_intents SET state='allocated' WHERE id=item.subscription_id AND organization_id=p_organization;
 END LOOP;
 PERFORM set_config('microfams.investment_allocation_execution_engine','off',TRUE); PERFORM set_config('microfams.investment_unit_engine','off',TRUE); PERFORM set_config('microfams.investment_subscription_engine','off',TRUE);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'INVESTMENT_ALLOCATION_PLAN_EXECUTED','investment_allocation_plan',plan.id::TEXT,jsonb_build_object('execution_id',execution.id,'subscription_count',expected_subscriptions,'unit_count',expected_units,'allocated_principal_minor',expected_principal,'refund_provider_submission','disabled'),p_at);
 RETURN jsonb_build_object('execution',to_jsonb(execution),'units',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.allocated_at,u.id) FROM investment_units u JOIN investment_allocation_plan_items i ON i.subscription_id=u.subscription_id AND i.organization_id=u.organization_id WHERE i.plan_id=plan.id));
END $$;

ALTER TABLE investment_allocation_executions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_allocation_executions FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_allocation_executions FROM service_role;
GRANT SELECT ON investment_allocation_executions TO service_role;
REVOKE ALL ON FUNCTION execute_investment_allocation_plan(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION execute_investment_allocation_plan(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
