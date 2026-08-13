-- INV-01: governed investment products and immutable risk disclosures.
SET search_path = public, extensions;

CREATE TABLE investment_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
  code TEXT NOT NULL CHECK (code~'^[A-Z0-9][A-Z0-9._-]{1,39}$'), name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 160),
  currency VARCHAR(3) NOT NULL CHECK (currency~'^[A-Z]{3}$'), state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','compliance_review','approved','cancelled')),
  current_version INTEGER NOT NULL DEFAULT 1 CHECK (current_version>0), created_by UUID NOT NULL REFERENCES users(id),
  creation_key TEXT NOT NULL CHECK (length(creation_key) BETWEEN 8 AND 160), creation_hash VARCHAR(64) NOT NULL CHECK (creation_hash~'^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE(organization_id,code), UNIQUE(organization_id,creation_key), UNIQUE(id,organization_id)
);
CREATE TABLE investment_product_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, product_id UUID NOT NULL, version INTEGER NOT NULL CHECK(version>0),
  state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN ('draft','compliance_review','approved','retired')),
  issuer_name TEXT NOT NULL CHECK(length(btrim(issuer_name)) BETWEEN 2 AND 160), operator_name TEXT NOT NULL CHECK(length(btrim(operator_name)) BETWEEN 2 AND 160),
  underlying_reference TEXT NOT NULL CHECK(length(btrim(underlying_reference)) BETWEEN 3 AND 200), funding_target_minor BIGINT NOT NULL CHECK(funding_target_minor>0),
  minimum_subscription_minor BIGINT NOT NULL CHECK(minimum_subscription_minor>0), maximum_subscription_minor BIGINT NOT NULL CHECK(maximum_subscription_minor>=minimum_subscription_minor),
  offer_opens_at TIMESTAMPTZ NOT NULL, offer_closes_at TIMESTAMPTZ NOT NULL, unit_method TEXT NOT NULL CHECK(unit_method IN ('fixed_unit_price','ownership_percentage')),
  unit_price_minor BIGINT CHECK(unit_price_minor IS NULL OR unit_price_minor>0), oversubscription_policy TEXT NOT NULL CHECK(oversubscription_policy IN ('pro_rata','first_settled')),
  fees JSONB NOT NULL CHECK(jsonb_typeof(fees)='array'), expected_return_disclosure TEXT NOT NULL CHECK(length(btrim(expected_return_disclosure)) BETWEEN 12 AND 500),
  loss_allocation_rule JSONB NOT NULL CHECK(jsonb_typeof(loss_allocation_rule)='object'), reporting_schedule JSONB NOT NULL CHECK(jsonb_typeof(reporting_schedule)='object'),
  maturity_at TIMESTAMPTZ NOT NULL, exit_rules JSONB NOT NULL CHECK(jsonb_typeof(exit_rules)='object'), jurisdiction_eligibility JSONB NOT NULL CHECK(jsonb_typeof(jurisdiction_eligibility)='object'),
  risk_disclosure_version TEXT NOT NULL CHECK(length(btrim(risk_disclosure_version)) BETWEEN 1 AND 80), risk_disclosure_hash VARCHAR(64) NOT NULL CHECK(risk_disclosure_hash~'^[a-f0-9]{64}$'),
  conflicts_disclosure TEXT NOT NULL CHECK(length(btrim(conflicts_disclosure)) BETWEEN 12 AND 500), created_by UUID NOT NULL REFERENCES users(id), submitted_at TIMESTAMPTZ,
  approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(product_id,organization_id) REFERENCES investment_products(id,organization_id), UNIQUE(organization_id,product_id,version), UNIQUE(id,organization_id),
  CHECK(offer_closes_at>offer_opens_at), CHECK(maturity_at>offer_closes_at), CHECK((unit_method='fixed_unit_price')=(unit_price_minor IS NOT NULL)),
  CHECK(approved_by IS NULL OR approved_by<>created_by), CHECK((state='approved' AND approved_by IS NOT NULL AND approved_at IS NOT NULL) OR state<>'approved')
);
CREATE UNIQUE INDEX uq_investment_product_approved_version ON investment_product_versions(organization_id,product_id) WHERE state='approved';
CREATE TABLE investment_product_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, product_id UUID NOT NULL, product_version_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('product_created','submitted','approved')), actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160), request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'), occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(product_id,organization_id) REFERENCES investment_products(id,organization_id), FOREIGN KEY(product_version_id,organization_id) REFERENCES investment_product_versions(id,organization_id),
  UNIQUE(organization_id,idempotency_key)
);

CREATE OR REPLACE FUNCTION require_investment_product_engine() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_product_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment product evidence is immutable outside the engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_products_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_products FOR EACH ROW EXECUTE FUNCTION require_investment_product_engine();
CREATE TRIGGER investment_product_versions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_product_versions FOR EACH ROW EXECUTE FUNCTION require_investment_product_engine();
CREATE TRIGGER investment_product_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_product_events FOR EACH ROW EXECUTE FUNCTION require_investment_product_engine();

CREATE OR REPLACE FUNCTION validate_investment_product_facts(f JSONB) RETURNS VOID LANGUAGE plpgsql IMMUTABLE SET search_path=public AS $$
BEGIN
 IF jsonb_typeof(f)<>'object' OR length(btrim(COALESCE(f->>'issuerName',''))) NOT BETWEEN 2 AND 160 OR length(btrim(COALESCE(f->>'operatorName',''))) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Investment issuer and operator are invalid'; END IF;
 IF (f->>'fundingTargetMinor')::BIGINT<=0 OR (f->>'minimumSubscriptionMinor')::BIGINT<=0 OR (f->>'maximumSubscriptionMinor')::BIGINT<(f->>'minimumSubscriptionMinor')::BIGINT THEN RAISE EXCEPTION 'Investment subscription limits are invalid'; END IF;
 IF (f->>'offerClosesAt')::TIMESTAMPTZ<=(f->>'offerOpensAt')::TIMESTAMPTZ OR (f->>'maturityAt')::TIMESTAMPTZ<=(f->>'offerClosesAt')::TIMESTAMPTZ THEN RAISE EXCEPTION 'Investment offer or maturity dates are invalid'; END IF;
 IF f->>'unitMethod' NOT IN ('fixed_unit_price','ownership_percentage') OR f->>'oversubscriptionPolicy' NOT IN ('pro_rata','first_settled') THEN RAISE EXCEPTION 'Investment allocation rules are invalid'; END IF;
 IF (f->>'unitMethod'='fixed_unit_price')<>(f ? 'unitPriceMinor' AND f->>'unitPriceMinor' IS NOT NULL) THEN RAISE EXCEPTION 'Fixed-unit investments require a unit price'; END IF;
 IF jsonb_typeof(f->'fees')<>'array' OR jsonb_typeof(f->'lossAllocationRule')<>'object' OR jsonb_typeof(f->'reportingSchedule')<>'object' OR jsonb_typeof(f->'exitRules')<>'object' OR jsonb_typeof(f->'jurisdictionEligibility')<>'object' THEN RAISE EXCEPTION 'Investment governance rules are incomplete'; END IF;
 IF length(btrim(COALESCE(f->>'expectedReturnDisclosure',''))) NOT BETWEEN 12 AND 500 OR length(btrim(COALESCE(f->>'conflictsDisclosure',''))) NOT BETWEEN 12 AND 500 OR COALESCE(f->>'riskDisclosureHash','')!~'^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Investment disclosures are invalid'; END IF;
END $$;

CREATE OR REPLACE FUNCTION create_investment_product_draft(p_organization UUID,p_actor UUID,p_code TEXT,p_name TEXT,p_currency TEXT,p_facts JSONB,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.configure') THEN RAISE EXCEPTION 'Missing financial.investments.configure permission'; END IF;
 PERFORM validate_investment_product_facts(p_facts);
 IF upper(p_code)!~'^[A-Z0-9][A-Z0-9._-]{1,39}$' OR upper(p_currency)!~'^[A-Z]{3}$' OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Investment product identity is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,upper(p_code),btrim(p_name),upper(p_currency),p_facts::TEXT,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-product:'||p_idempotency_key,0));
 SELECT * INTO p FROM investment_products WHERE organization_id=p_organization AND creation_key=p_idempotency_key;
 IF p.id IS NOT NULL THEN IF p.creation_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment product facts'; END IF; SELECT * INTO v FROM investment_product_versions WHERE product_id=p.id AND version=1; RETURN jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v)); END IF;
 PERFORM set_config('microfams.investment_product_engine','on',TRUE);
 INSERT INTO investment_products(organization_id,code,name,currency,created_by,creation_key,creation_hash,created_at,updated_at) VALUES(p_organization,upper(p_code),btrim(p_name),upper(p_currency),p_actor,p_idempotency_key,h,p_at,p_at) RETURNING * INTO p;
 INSERT INTO investment_product_versions(organization_id,product_id,version,issuer_name,operator_name,underlying_reference,funding_target_minor,minimum_subscription_minor,maximum_subscription_minor,offer_opens_at,offer_closes_at,unit_method,unit_price_minor,oversubscription_policy,fees,expected_return_disclosure,loss_allocation_rule,reporting_schedule,maturity_at,exit_rules,jurisdiction_eligibility,risk_disclosure_version,risk_disclosure_hash,conflicts_disclosure,created_by,created_at)
 VALUES(p_organization,p.id,1,btrim(p_facts->>'issuerName'),btrim(p_facts->>'operatorName'),btrim(p_facts->>'underlyingReference'),(p_facts->>'fundingTargetMinor')::BIGINT,(p_facts->>'minimumSubscriptionMinor')::BIGINT,(p_facts->>'maximumSubscriptionMinor')::BIGINT,(p_facts->>'offerOpensAt')::TIMESTAMPTZ,(p_facts->>'offerClosesAt')::TIMESTAMPTZ,p_facts->>'unitMethod',(p_facts->>'unitPriceMinor')::BIGINT,p_facts->>'oversubscriptionPolicy',p_facts->'fees',btrim(p_facts->>'expectedReturnDisclosure'),p_facts->'lossAllocationRule',p_facts->'reportingSchedule',(p_facts->>'maturityAt')::TIMESTAMPTZ,p_facts->'exitRules',p_facts->'jurisdictionEligibility',btrim(p_facts->>'riskDisclosureVersion'),lower(p_facts->>'riskDisclosureHash'),btrim(p_facts->>'conflictsDisclosure'),p_actor,p_at) RETURNING * INTO v;
 INSERT INTO investment_product_events VALUES(gen_random_uuid(),p_organization,p.id,v.id,'product_created',p_actor,p_idempotency_key,h,jsonb_build_object('version',1,'risk_disclosure_version',v.risk_disclosure_version),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_PRODUCT_DRAFTED','investment_product',p.id::TEXT,jsonb_build_object('version',1,'risk_disclosure_version',v.risk_disclosure_version),p_at);
 RETURN jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v));
END $$;

CREATE OR REPLACE FUNCTION submit_investment_product(p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; e investment_product_events; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.configure') THEN RAISE EXCEPTION 'Missing financial.investments.configure permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_product,p_version,'submit',p_idempotency_key),'UTF8'),'sha256'),'hex'); SELECT * INTO e FROM investment_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment command facts'; END IF; SELECT * INTO v FROM investment_product_versions WHERE id=e.product_version_id; RETURN to_jsonb(v); END IF;
 SELECT * INTO p FROM investment_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE; SELECT * INTO v FROM investment_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_version FOR UPDATE;
 IF p.state<>'draft' OR v.state<>'draft' THEN RAISE EXCEPTION 'Investment product is not an expected draft'; END IF;
 PERFORM set_config('microfams.investment_product_engine','on',TRUE); UPDATE investment_products SET state='compliance_review',updated_at=p_at WHERE id=p.id; UPDATE investment_product_versions SET state='compliance_review',submitted_at=p_at WHERE id=v.id RETURNING * INTO v;
 INSERT INTO investment_product_events VALUES(gen_random_uuid(),p_organization,p.id,v.id,'submitted',p_actor,p_idempotency_key,h,jsonb_build_object('version',p_version),p_at); RETURN to_jsonb(v);
END $$;

CREATE OR REPLACE FUNCTION approve_investment_product(p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE p investment_products; v investment_product_versions; e investment_product_events; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.configure') THEN RAISE EXCEPTION 'Missing financial.investments.configure permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_product,p_version,'approve',p_idempotency_key),'UTF8'),'sha256'),'hex'); SELECT * INTO e FROM investment_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different investment command facts'; END IF; SELECT * INTO v FROM investment_product_versions WHERE id=e.product_version_id; RETURN jsonb_build_object('version',to_jsonb(v)); END IF;
 SELECT * INTO p FROM investment_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE; SELECT * INTO v FROM investment_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_version FOR UPDATE;
 IF p.state<>'compliance_review' OR v.state<>'compliance_review' THEN RAISE EXCEPTION 'Investment product is not pending compliance approval'; END IF; IF v.created_by=p_actor THEN RAISE EXCEPTION 'Investment product requires independent compliance approval'; END IF;
 PERFORM set_config('microfams.investment_product_engine','on',TRUE); UPDATE investment_products SET state='approved',updated_at=p_at WHERE id=p.id RETURNING * INTO p; UPDATE investment_product_versions SET state='approved',approved_by=p_actor,approved_at=p_at WHERE id=v.id RETURNING * INTO v;
 INSERT INTO investment_product_events VALUES(gen_random_uuid(),p_organization,p.id,v.id,'approved',p_actor,p_idempotency_key,h,jsonb_build_object('version',p_version),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at) VALUES(p_organization,p_actor,'INVESTMENT_PRODUCT_APPROVED','investment_product',p.id::TEXT,jsonb_build_object('version',p_version,'approved_by',p_actor),p_at);
 RETURN jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v));
END $$;

INSERT INTO feature_flags(key,domain,description,default_enabled,failure_mode,risk) VALUES
('financial.investments.read','investments','Read approved investment products.',TRUE,'open','regulated'),
('financial.investments.configure','investments','Draft, submit, and independently approve investment products.',FALSE,'closed','regulated')
ON CONFLICT(key) DO UPDATE SET domain=EXCLUDED.domain,description=EXCLUDED.description,default_enabled=EXCLUDED.default_enabled,failure_mode=EXCLUDED.failure_mode,risk=EXCLUDED.risk,updated_at=NOW();
UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(permissions,'{}')||ARRAY['financial.investments.configure']) x) WHERE role='owner';
ALTER TABLE investment_products ENABLE ROW LEVEL SECURITY; ALTER TABLE investment_product_versions ENABLE ROW LEVEL SECURITY; ALTER TABLE investment_product_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_products,investment_product_versions,investment_product_events FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON investment_products,investment_product_versions,investment_product_events FROM service_role; GRANT SELECT ON investment_products,investment_product_versions,investment_product_events TO service_role;
REVOKE ALL ON FUNCTION validate_investment_product_facts(JSONB),create_investment_product_draft(UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ),submit_investment_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ),approve_investment_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_investment_product_draft(UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ),submit_investment_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ),approve_investment_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
