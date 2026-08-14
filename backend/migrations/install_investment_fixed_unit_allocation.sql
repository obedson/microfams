-- INV-05: allocate immutable fixed-price units after a non-oversubscribed offer closes.
SET search_path=public,extensions;

ALTER TABLE investment_subscription_intents DROP CONSTRAINT investment_subscription_intents_state_check;
ALTER TABLE investment_subscription_intents ADD CONSTRAINT investment_subscription_intents_state_check CHECK(state IN ('pending','settled','allocated','cancelled','expired'));

CREATE TABLE investment_units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, product_id UUID NOT NULL, product_version_id UUID NOT NULL,
  subscription_id UUID NOT NULL, investor_id UUID NOT NULL REFERENCES users(id), unit_count BIGINT NOT NULL CHECK(unit_count>0),
  unit_price_minor BIGINT NOT NULL CHECK(unit_price_minor>0), allocated_amount_minor BIGINT NOT NULL CHECK(allocated_amount_minor>0),
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'), idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL, allocated_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(product_id,organization_id) REFERENCES investment_products(id,organization_id),
  FOREIGN KEY(product_version_id,organization_id) REFERENCES investment_product_versions(id,organization_id),
  FOREIGN KEY(subscription_id,organization_id) REFERENCES investment_subscription_intents(id,organization_id),
  UNIQUE(organization_id,subscription_id), UNIQUE(organization_id,idempotency_key)
);
CREATE INDEX idx_investment_units_holder ON investment_units(organization_id,investor_id,product_id);

CREATE OR REPLACE FUNCTION protect_investment_units() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_unit_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment unit evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_units_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_units FOR EACH ROW EXECUTE FUNCTION protect_investment_units();

CREATE OR REPLACE FUNCTION prevent_settlement_after_unit_allocation() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF OLD.state='pending' AND NEW.state='settled' THEN
   PERFORM pg_advisory_xact_lock(hashtextextended(NEW.organization_id::TEXT||':investment-product-allocation:'||NEW.product_id::TEXT,0));
   IF EXISTS(SELECT 1 FROM investment_units u WHERE u.organization_id=NEW.organization_id AND u.product_id=NEW.product_id) THEN RAISE EXCEPTION 'Investment offer allocation has already started'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER investment_subscription_allocation_finality BEFORE UPDATE OF state ON investment_subscription_intents FOR EACH ROW EXECUTE FUNCTION prevent_settlement_after_unit_allocation();

CREATE OR REPLACE FUNCTION allocate_fixed_investment_units(p_organization UUID,p_actor UUID,p_subscription UUID,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE i investment_subscription_intents; p investment_products; v investment_product_versions; u investment_units; h TEXT; settled_total BIGINT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
 IF p_subscription IS NULL OR p_correlation IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Investment unit allocation command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_subscription,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-unit-allocation:'||p_idempotency_key,0));
 SELECT * INTO u FROM investment_units WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF u.id IS NOT NULL THEN
   IF u.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment allocation facts'; END IF;
   SELECT * INTO i FROM investment_subscription_intents WHERE id=u.subscription_id AND organization_id=p_organization;
   RETURN jsonb_build_object('subscription',to_jsonb(i),'units',to_jsonb(u));
 END IF;
 SELECT * INTO i FROM investment_subscription_intents WHERE id=p_subscription AND organization_id=p_organization FOR UPDATE;
 IF i.id IS NULL OR i.state<>'settled' OR NOT EXISTS(SELECT 1 FROM investment_subscription_settlements s WHERE s.subscription_id=i.id AND s.organization_id=p_organization) THEN RAISE EXCEPTION 'Investment subscription is not settled for allocation'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-product-allocation:'||i.product_id::TEXT,0));
 SELECT * INTO p FROM investment_products WHERE id=i.product_id AND organization_id=p_organization FOR UPDATE;
 SELECT * INTO v FROM investment_product_versions WHERE id=i.product_version_id AND organization_id=p_organization FOR SHARE;
 IF p.id IS NULL OR v.id IS NULL OR p.state<>'open' OR v.state<>'approved' OR p_at<=v.offer_closes_at THEN RAISE EXCEPTION 'Investment offer is not closed for allocation'; END IF;
 IF v.unit_method<>'fixed_unit_price' OR v.unit_price_minor IS NULL OR mod(i.requested_amount_minor,v.unit_price_minor)<>0 THEN RAISE EXCEPTION 'Investment subscription is not eligible for exact fixed-unit allocation'; END IF;
 SELECT COALESCE(sum(si.requested_amount_minor),0) INTO settled_total FROM investment_subscription_intents si WHERE si.organization_id=p_organization AND si.product_id=p.id AND si.state IN ('settled','allocated');
 IF settled_total>v.funding_target_minor THEN RAISE EXCEPTION 'Oversubscribed investment offers require governed allocation'; END IF;
 PERFORM set_config('microfams.investment_unit_engine','on',TRUE); PERFORM set_config('microfams.investment_subscription_engine','on',TRUE);
 INSERT INTO investment_units(organization_id,product_id,product_version_id,subscription_id,investor_id,unit_count,unit_price_minor,allocated_amount_minor,currency,idempotency_key,request_hash,correlation_id,allocated_at,created_at)
 VALUES(p_organization,p.id,v.id,i.id,i.investor_id,i.requested_amount_minor/v.unit_price_minor,v.unit_price_minor,i.requested_amount_minor,i.currency,p_idempotency_key,h,p_correlation,p_at,p_at) RETURNING * INTO u;
 UPDATE investment_subscription_intents SET state='allocated' WHERE id=i.id RETURNING * INTO i;
 PERFORM set_config('microfams.investment_unit_engine','off',TRUE); PERFORM set_config('microfams.investment_subscription_engine','off',TRUE);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_UNITS_ALLOCATED','investment_subscription_intent',i.id::TEXT,jsonb_build_object('product_id',p.id,'unit_count',u.unit_count,'unit_price_minor',u.unit_price_minor,'allocated_amount_minor',u.allocated_amount_minor),p_at);
 RETURN jsonb_build_object('subscription',to_jsonb(i),'units',to_jsonb(u));
END $$;

ALTER TABLE investment_units ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_units FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON investment_units FROM service_role; GRANT SELECT ON investment_units TO service_role;
REVOKE ALL ON FUNCTION allocate_fixed_investment_units(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION allocate_fixed_investment_units(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
