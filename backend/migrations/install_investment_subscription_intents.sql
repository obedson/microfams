-- INV-02: disclosure-bound investment subscription intents; no money movement or unit allocation.
SET search_path=public,extensions;

CREATE TABLE investment_subscription_intents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, product_id UUID NOT NULL,
  product_version_id UUID NOT NULL, investor_id UUID NOT NULL REFERENCES users(id), state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','cancelled','expired')),
  requested_amount_minor BIGINT NOT NULL CHECK(requested_amount_minor>0), currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  investor_country VARCHAR(2) NOT NULL CHECK(investor_country~'^[A-Z]{2}$'), investor_type TEXT NOT NULL CHECK(investor_type IN ('individual','group','organization')),
  accepted_risk_disclosure_version TEXT NOT NULL, accepted_risk_disclosure_hash VARCHAR(64) NOT NULL CHECK(accepted_risk_disclosure_hash~'^[a-f0-9]{64}$'),
  eligibility_snapshot JSONB NOT NULL CHECK(jsonb_typeof(eligibility_snapshot)='object'), requested_at TIMESTAMPTZ NOT NULL,
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160), request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL, FOREIGN KEY(product_id,organization_id) REFERENCES investment_products(id,organization_id),
  FOREIGN KEY(product_version_id,organization_id) REFERENCES investment_product_versions(id,organization_id), UNIQUE(organization_id,idempotency_key), UNIQUE(id,organization_id)
);
CREATE INDEX idx_investment_subscription_investor ON investment_subscription_intents(organization_id,investor_id,state,requested_at DESC);

UPDATE organization_memberships
SET permissions=ARRAY(
  SELECT DISTINCT permission
  FROM unnest(COALESCE(permissions,'{}')||ARRAY['financial.investments.subscribe']) permission
)
WHERE role='owner';

CREATE OR REPLACE FUNCTION require_investment_subscription_engine() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_subscription_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment subscription evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_subscription_intents_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_subscription_intents FOR EACH ROW EXECUTE FUNCTION require_investment_subscription_engine();

CREATE OR REPLACE FUNCTION create_investment_subscription_intent(p_organization UUID,p_actor UUID,p_product UUID,p_amount_minor BIGINT,p_country TEXT,p_investor_type TEXT,p_disclosure_version TEXT,p_disclosure_hash TEXT,p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; i investment_subscription_intents; h TEXT; allowed_countries TEXT[]; allowed_types TEXT[]; eligibility JSONB;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.subscribe') THEN RAISE EXCEPTION 'Missing financial.investments.subscribe permission'; END IF;
 IF p_product IS NULL OR p_amount_minor IS NULL OR p_amount_minor<=0 OR COALESCE(upper(p_country),'')!~'^[A-Z]{2}$' OR COALESCE(p_investor_type,'') NOT IN ('individual','group','organization') OR length(btrim(COALESCE(p_disclosure_version,''))) NOT BETWEEN 1 AND 80 OR COALESCE(lower(p_disclosure_hash),'')!~'^[a-f0-9]{64}$' OR p_correlation IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment subscription intent is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_product,p_amount_minor,upper(p_country),p_investor_type,p_disclosure_version,lower(p_disclosure_hash),p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-subscription:'||p_idempotency_key,0)); SELECT * INTO i FROM investment_subscription_intents WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF i.id IS NOT NULL THEN IF i.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment subscription facts'; END IF; RETURN jsonb_build_object('subscription',to_jsonb(i)); END IF;
 SELECT * INTO p FROM investment_products WHERE id=p_product AND organization_id=p_organization; SELECT * INTO v FROM investment_product_versions WHERE product_id=p_product AND organization_id=p_organization AND state='approved';
 IF p.id IS NULL OR p.state<>'open' OR v.id IS NULL THEN RAISE EXCEPTION 'Investment product is not available for subscription'; END IF;
 IF p_at<v.offer_opens_at OR p_at>v.offer_closes_at THEN RAISE EXCEPTION 'Investment offer window is closed'; END IF;
 IF p_amount_minor<v.minimum_subscription_minor OR p_amount_minor>v.maximum_subscription_minor THEN RAISE EXCEPTION 'Investment subscription amount is outside product limits'; END IF;
 IF btrim(p_disclosure_version)<>v.risk_disclosure_version OR lower(p_disclosure_hash)<>v.risk_disclosure_hash THEN RAISE EXCEPTION 'Accepted risk disclosure does not match the approved product version'; END IF;
 allowed_countries:=ARRAY(SELECT upper(value) FROM jsonb_array_elements_text(COALESCE(v.jurisdiction_eligibility->'countries','[]'::JSONB))); allowed_types:=ARRAY(SELECT lower(value) FROM jsonb_array_elements_text(COALESCE(v.jurisdiction_eligibility->'investorTypes','[]'::JSONB)));
 IF cardinality(allowed_countries)=0 OR cardinality(allowed_types)=0 OR NOT upper(p_country)=ANY(allowed_countries) OR NOT lower(p_investor_type)=ANY(allowed_types) THEN RAISE EXCEPTION 'Investor is not eligible for this investment product'; END IF;
 eligibility:=jsonb_build_object('country',upper(p_country),'investorType',p_investor_type,'jurisdictionRule',v.jurisdiction_eligibility,'checkedAt',p_at);
 PERFORM set_config('microfams.investment_subscription_engine','on',TRUE);
 INSERT INTO investment_subscription_intents(organization_id,product_id,product_version_id,investor_id,requested_amount_minor,currency,investor_country,investor_type,accepted_risk_disclosure_version,accepted_risk_disclosure_hash,eligibility_snapshot,requested_at,idempotency_key,request_hash,correlation_id,created_at)
 VALUES(p_organization,p.id,v.id,p_actor,p_amount_minor,p.currency,upper(p_country),p_investor_type,v.risk_disclosure_version,v.risk_disclosure_hash,eligibility,p_at,p_idempotency_key,h,p_correlation,p_at) RETURNING * INTO i;
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_SUBSCRIPTION_INTENT_CREATED','investment_subscription_intent',i.id::TEXT,jsonb_build_object('product_id',p.id,'product_version_id',v.id,'amount_minor',p_amount_minor,'state','pending'),p_at);
 RETURN jsonb_build_object('subscription',to_jsonb(i));
END $$;

ALTER TABLE investment_subscription_intents ENABLE ROW LEVEL SECURITY; REVOKE ALL ON investment_subscription_intents FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON investment_subscription_intents FROM service_role; GRANT SELECT ON investment_subscription_intents TO service_role;
REVOKE ALL ON FUNCTION create_investment_subscription_intent(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION create_investment_subscription_intent(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) TO service_role;
