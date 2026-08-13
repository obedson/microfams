-- INV-03: governed activation of approved investment offer windows.
SET search_path=public,extensions;

ALTER TABLE investment_products DROP CONSTRAINT investment_products_state_check;
ALTER TABLE investment_products ADD CONSTRAINT investment_products_state_check
  CHECK(state IN ('draft','compliance_review','approved','open','cancelled'));

ALTER TABLE investment_product_events DROP CONSTRAINT investment_product_events_action_check;
ALTER TABLE investment_product_events ADD CONSTRAINT investment_product_events_action_check
  CHECK(action IN ('product_created','submitted','approved','opened'));

CREATE OR REPLACE FUNCTION open_investment_product_offer(
  p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; e investment_product_events; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.configure') THEN RAISE EXCEPTION 'Missing financial.investments.configure permission'; END IF;
 IF p_product IS NULL OR p_version IS NULL OR p_version<1 OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Investment offer opening command is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_product,p_version,'open',p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-product-open:'||p_idempotency_key,0));
 SELECT * INTO e FROM investment_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h OR e.action<>'opened' THEN RAISE EXCEPTION 'Idempotency key reused with different investment command facts'; END IF; SELECT * INTO p FROM investment_products WHERE id=e.product_id; SELECT * INTO v FROM investment_product_versions WHERE id=e.product_version_id; RETURN jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v)); END IF;
 SELECT * INTO p FROM investment_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
 SELECT * INTO v FROM investment_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_version FOR UPDATE;
 IF p.id IS NULL OR v.id IS NULL OR p.state<>'approved' OR v.state<>'approved' THEN RAISE EXCEPTION 'Investment product is not approved for offer opening'; END IF;
 IF p_at<v.offer_opens_at OR p_at>v.offer_closes_at THEN RAISE EXCEPTION 'Investment offer cannot open outside its approved window'; END IF;
 PERFORM set_config('microfams.investment_product_engine','on',TRUE);
 UPDATE investment_products SET state='open',updated_at=p_at WHERE id=p.id RETURNING * INTO p;
 INSERT INTO investment_product_events VALUES(gen_random_uuid(),p_organization,p.id,v.id,'opened',p_actor,p_idempotency_key,h,jsonb_build_object('version',p_version,'opened_at',p_at),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_OFFER_OPENED','investment_product',p.id::TEXT,jsonb_build_object('version',p_version,'offer_opens_at',v.offer_opens_at,'offer_closes_at',v.offer_closes_at),p_at);
 RETURN jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v));
END $$;

REVOKE ALL ON FUNCTION open_investment_product_offer(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION open_investment_product_offer(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
