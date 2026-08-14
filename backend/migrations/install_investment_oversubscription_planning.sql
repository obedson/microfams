-- INV-06: deterministic oversubscription plans and maker-checker approval; no execution.
SET search_path=public,extensions;

CREATE TABLE investment_allocation_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, product_id UUID NOT NULL, product_version_id UUID NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN ('draft','approved')), policy TEXT NOT NULL CHECK(policy IN ('pro_rata','first_settled')),
  settlement_cutoff TIMESTAMPTZ NOT NULL, available_units BIGINT NOT NULL CHECK(available_units>0), requested_units BIGINT NOT NULL CHECK(requested_units>available_units),
  allocated_units BIGINT NOT NULL DEFAULT 0 CHECK(allocated_units>=0), total_settled_minor BIGINT NOT NULL CHECK(total_settled_minor>0),
  allocated_principal_minor BIGINT NOT NULL DEFAULT 0 CHECK(allocated_principal_minor>=0), refund_due_minor BIGINT NOT NULL DEFAULT 0 CHECK(refund_due_minor>=0),
  created_by UUID NOT NULL REFERENCES users(id), approved_by UUID REFERENCES users(id), creation_key TEXT NOT NULL CHECK(length(creation_key) BETWEEN 8 AND 160),
  creation_hash VARCHAR(64) NOT NULL CHECK(creation_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL, created_at TIMESTAMPTZ NOT NULL, approved_at TIMESTAMPTZ,
  FOREIGN KEY(product_id,organization_id) REFERENCES investment_products(id,organization_id), FOREIGN KEY(product_version_id,organization_id) REFERENCES investment_product_versions(id,organization_id),
  UNIQUE(organization_id,product_version_id), UNIQUE(organization_id,creation_key), UNIQUE(id,organization_id),
  CHECK((state='approved' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND approved_by<>created_by) OR (state='draft' AND approved_by IS NULL AND approved_at IS NULL))
);
CREATE TABLE investment_allocation_plan_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, plan_id UUID NOT NULL, subscription_id UUID NOT NULL, settlement_id UUID NOT NULL,
  settlement_at TIMESTAMPTZ NOT NULL, requested_units BIGINT NOT NULL CHECK(requested_units>0), allocated_units BIGINT NOT NULL CHECK(allocated_units>=0),
  remainder_numerator NUMERIC NOT NULL DEFAULT 0 CHECK(remainder_numerator>=0), allocated_principal_minor BIGINT NOT NULL CHECK(allocated_principal_minor>=0),
  refund_due_minor BIGINT NOT NULL CHECK(refund_due_minor>=0), allocation_rank INTEGER NOT NULL CHECK(allocation_rank>0), created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(plan_id,organization_id) REFERENCES investment_allocation_plans(id,organization_id),
  FOREIGN KEY(subscription_id,organization_id) REFERENCES investment_subscription_intents(id,organization_id),
  FOREIGN KEY(settlement_id) REFERENCES settlements(id), UNIQUE(organization_id,plan_id,subscription_id), UNIQUE(organization_id,plan_id,allocation_rank)
);
CREATE TABLE investment_allocation_plan_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, plan_id UUID NOT NULL, action TEXT NOT NULL CHECK(action IN ('created','approved')),
  actor_id UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'), occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(plan_id,organization_id) REFERENCES investment_allocation_plans(id,organization_id), UNIQUE(organization_id,idempotency_key)
);

CREATE OR REPLACE FUNCTION protect_investment_allocation_plans() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_allocation_plan_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment allocation plan evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_allocation_plans_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_allocation_plans FOR EACH ROW EXECUTE FUNCTION protect_investment_allocation_plans();
CREATE TRIGGER investment_allocation_plan_items_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_allocation_plan_items FOR EACH ROW EXECUTE FUNCTION protect_investment_allocation_plans();
CREATE TRIGGER investment_allocation_plan_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_allocation_plan_events FOR EACH ROW EXECUTE FUNCTION protect_investment_allocation_plans();

CREATE OR REPLACE FUNCTION prevent_settlement_after_allocation_plan() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF OLD.state='pending' AND NEW.state='settled' THEN
   PERFORM pg_advisory_xact_lock(hashtextextended(NEW.organization_id::TEXT||':investment-product-allocation:'||NEW.product_id::TEXT,0));
   IF EXISTS(SELECT 1 FROM investment_allocation_plans p WHERE p.organization_id=NEW.organization_id AND p.product_id=NEW.product_id) THEN RAISE EXCEPTION 'Investment offer allocation planning has already started'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER investment_subscription_plan_finality BEFORE UPDATE OF state ON investment_subscription_intents FOR EACH ROW EXECUTE FUNCTION prevent_settlement_after_allocation_plan();

CREATE OR REPLACE FUNCTION create_investment_allocation_plan(p_organization UUID,p_actor UUID,p_product UUID,p_settlement_cutoff TIMESTAMPTZ,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; plan investment_allocation_plans; h TEXT; total_minor BIGINT; total_units BIGINT; capacity BIGINT; leftover BIGINT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_product IS NULL OR p_settlement_cutoff IS NULL OR p_correlation IS NULL OR p_at IS NULL OR p_settlement_cutoff>p_at OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment allocation plan command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_product,p_settlement_cutoff,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-product-allocation:'||p_product::TEXT,0));
 SELECT * INTO plan FROM investment_allocation_plans WHERE organization_id=p_organization AND creation_key=p_idempotency_key;
 IF plan.id IS NOT NULL THEN IF plan.creation_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different allocation plan facts'; END IF; RETURN jsonb_build_object('plan',to_jsonb(plan),'items',(SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.allocation_rank),'[]'::JSONB) FROM investment_allocation_plan_items i WHERE i.plan_id=plan.id)); END IF;
 SELECT * INTO p FROM investment_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
 SELECT * INTO v FROM investment_product_versions WHERE product_id=p_product AND organization_id=p_organization AND state='approved' FOR SHARE;
 IF p.id IS NULL OR v.id IS NULL OR p.state<>'open' OR p_at<=v.offer_closes_at OR p_settlement_cutoff<v.offer_closes_at OR v.unit_method<>'fixed_unit_price' OR v.unit_price_minor IS NULL THEN RAISE EXCEPTION 'Investment offer is not eligible for oversubscription planning'; END IF;
 IF EXISTS(SELECT 1 FROM investment_subscription_intents i JOIN investment_subscription_settlements ss ON ss.subscription_id=i.id AND ss.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.product_id=p.id AND i.state='settled' AND (ss.settled_at>p_settlement_cutoff OR mod(i.requested_amount_minor,v.unit_price_minor)<>0)) THEN RAISE EXCEPTION 'Investment settlements are not finalized or exactly unitized'; END IF;
 SELECT COALESCE(sum(i.requested_amount_minor),0),COALESCE(sum(i.requested_amount_minor/v.unit_price_minor),0) INTO total_minor,total_units FROM investment_subscription_intents i JOIN investment_subscription_settlements ss ON ss.subscription_id=i.id AND ss.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.product_id=p.id AND i.state='settled' AND ss.settled_at<=p_settlement_cutoff;
 capacity:=v.funding_target_minor/v.unit_price_minor;
 IF capacity<=0 OR total_units<=capacity THEN RAISE EXCEPTION 'Investment offer is not oversubscribed in whole units'; END IF;
 PERFORM set_config('microfams.investment_allocation_plan_engine','on',TRUE);
 INSERT INTO investment_allocation_plans(organization_id,product_id,product_version_id,policy,settlement_cutoff,available_units,requested_units,total_settled_minor,created_by,creation_key,creation_hash,correlation_id,created_at)
 VALUES(p_organization,p.id,v.id,v.oversubscription_policy,p_settlement_cutoff,capacity,total_units,total_minor,p_actor,p_idempotency_key,h,p_correlation,p_at) RETURNING * INTO plan;
 IF v.oversubscription_policy='pro_rata' THEN
   INSERT INTO investment_allocation_plan_items(organization_id,plan_id,subscription_id,settlement_id,settlement_at,requested_units,allocated_units,remainder_numerator,allocated_principal_minor,refund_due_minor,allocation_rank,created_at)
   SELECT p_organization,plan.id,i.id,ss.settlement_id,ss.settled_at settlement_at,i.requested_amount_minor/v.unit_price_minor,floor(((i.requested_amount_minor/v.unit_price_minor)::NUMERIC*capacity)/total_units)::BIGINT,mod((i.requested_amount_minor/v.unit_price_minor)::NUMERIC*capacity,total_units),0,0,row_number() OVER(ORDER BY ss.settled_at,i.id),p_at
   FROM investment_subscription_intents i JOIN investment_subscription_settlements ss ON ss.subscription_id=i.id AND ss.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.product_id=p.id AND i.state='settled' ORDER BY ss.settled_at,i.id;
   SELECT capacity-sum(allocated_units) INTO leftover FROM investment_allocation_plan_items WHERE plan_id=plan.id;
   UPDATE investment_allocation_plan_items x SET allocated_units=x.allocated_units+1 WHERE x.id IN (SELECT id FROM investment_allocation_plan_items WHERE plan_id=plan.id ORDER BY remainder_numerator DESC,settlement_at,subscription_id LIMIT leftover);
 ELSE
   INSERT INTO investment_allocation_plan_items(organization_id,plan_id,subscription_id,settlement_id,settlement_at,requested_units,allocated_units,remainder_numerator,allocated_principal_minor,refund_due_minor,allocation_rank,created_at)
   SELECT p_organization,plan.id,q.subscription_id,q.settlement_id,q.settlement_at,q.requested_units,GREATEST(LEAST(q.requested_units,capacity-q.prior_units),0),0,0,0,q.allocation_rank,p_at FROM (
     SELECT i.id subscription_id,ss.settlement_id,ss.settled_at settlement_at,i.requested_amount_minor/v.unit_price_minor requested_units,COALESCE(sum(i.requested_amount_minor/v.unit_price_minor) OVER(ORDER BY ss.settled_at,i.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior_units,row_number() OVER(ORDER BY ss.settled_at,i.id) allocation_rank
     FROM investment_subscription_intents i JOIN investment_subscription_settlements ss ON ss.subscription_id=i.id AND ss.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.product_id=p.id AND i.state='settled'
   ) q ORDER BY q.allocation_rank;
 END IF;
 UPDATE investment_allocation_plan_items x SET allocated_principal_minor=x.allocated_units*v.unit_price_minor,refund_due_minor=x.requested_units*v.unit_price_minor-x.allocated_units*v.unit_price_minor WHERE x.plan_id=plan.id;
 UPDATE investment_allocation_plans x SET allocated_units=t.units,allocated_principal_minor=t.principal,refund_due_minor=t.refund FROM (SELECT sum(allocated_units) units,sum(allocated_principal_minor) principal,sum(refund_due_minor) refund FROM investment_allocation_plan_items WHERE plan_id=plan.id) t WHERE x.id=plan.id RETURNING x.* INTO plan;
 INSERT INTO investment_allocation_plan_events VALUES(gen_random_uuid(),p_organization,plan.id,'created',p_actor,p_idempotency_key,h,jsonb_build_object('policy',plan.policy,'available_units',plan.available_units,'requested_units',plan.requested_units,'refund_due_minor',plan.refund_due_minor),p_at);
 PERFORM set_config('microfams.investment_allocation_plan_engine','off',TRUE);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_ALLOCATION_PLAN_CREATED','investment_allocation_plan',plan.id::TEXT,jsonb_build_object('product_id',p.id,'policy',plan.policy,'refund_due_minor',plan.refund_due_minor),p_at);
 RETURN jsonb_build_object('plan',to_jsonb(plan),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.allocation_rank) FROM investment_allocation_plan_items i WHERE i.plan_id=plan.id));
END $$;

CREATE OR REPLACE FUNCTION approve_investment_allocation_plan(p_organization UUID,p_actor UUID,p_plan UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE plan investment_allocation_plans; e investment_allocation_plan_events; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_plan IS NULL OR p_at IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment allocation approval command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_plan,'approve',p_idempotency_key),'UTF8'),'sha256'),'hex');
 SELECT * INTO e FROM investment_allocation_plan_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h OR e.action<>'approved' THEN RAISE EXCEPTION 'Idempotency key reused with different allocation approval facts'; END IF; SELECT * INTO plan FROM investment_allocation_plans WHERE id=e.plan_id; RETURN jsonb_build_object('plan',to_jsonb(plan)); END IF;
 SELECT * INTO plan FROM investment_allocation_plans WHERE id=p_plan AND organization_id=p_organization FOR UPDATE;
 IF plan.id IS NULL OR plan.state<>'draft' OR plan.created_by=p_actor OR plan.allocated_units<>plan.available_units OR plan.total_settled_minor<>plan.allocated_principal_minor+plan.refund_due_minor THEN RAISE EXCEPTION 'Investment allocation plan is not eligible for independent approval'; END IF;
 PERFORM set_config('microfams.investment_allocation_plan_engine','on',TRUE);
 UPDATE investment_allocation_plans SET state='approved',approved_by=p_actor,approved_at=p_at WHERE id=plan.id RETURNING * INTO plan;
 INSERT INTO investment_allocation_plan_events VALUES(gen_random_uuid(),p_organization,plan.id,'approved',p_actor,p_idempotency_key,h,jsonb_build_object('allocated_units',plan.allocated_units,'refund_due_minor',plan.refund_due_minor),p_at);
 PERFORM set_config('microfams.investment_allocation_plan_engine','off',TRUE);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_ALLOCATION_PLAN_APPROVED','investment_allocation_plan',plan.id::TEXT,jsonb_build_object('approved_by',p_actor,'refund_execution','disabled'),p_at);
 RETURN jsonb_build_object('plan',to_jsonb(plan));
END $$;

ALTER TABLE investment_allocation_plans ENABLE ROW LEVEL SECURITY; ALTER TABLE investment_allocation_plan_items ENABLE ROW LEVEL SECURITY; ALTER TABLE investment_allocation_plan_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_allocation_plans,investment_allocation_plan_items,investment_allocation_plan_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_allocation_plans,investment_allocation_plan_items,investment_allocation_plan_events FROM service_role;
GRANT SELECT ON investment_allocation_plans,investment_allocation_plan_items,investment_allocation_plan_events TO service_role;
REVOKE ALL ON FUNCTION create_investment_allocation_plan(UUID,UUID,UUID,TIMESTAMPTZ,UUID,TEXT,TIMESTAMPTZ),approve_investment_allocation_plan(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_investment_allocation_plan(UUID,UUID,UUID,TIMESTAMPTZ,UUID,TEXT,TIMESTAMPTZ),approve_investment_allocation_plan(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;

