-- DIV-01 immutable proportional paid-unit distribution calculations; no approval or payment.
SET search_path=public,extensions;
CREATE TABLE dividend_distributions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),source_period_id UUID NOT NULL REFERENCES accounting_periods(id),
 distribution_key TEXT NOT NULL CHECK(distribution_key~'^[a-z][a-z0-9_-]{1,47}$'),currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),state TEXT NOT NULL DEFAULT 'calculated' CHECK(state IN('calculated','reviewed','approved','payable','paying','paid','corrected')),
 distributable_minor BIGINT NOT NULL CHECK(distributable_minor>0),retained_reserve_minor BIGINT NOT NULL CHECK(retained_reserve_minor>=0),eligible_units BIGINT NOT NULL CHECK(eligible_units>0),allocated_minor BIGINT NOT NULL CHECK(allocated_minor>=0),rounding_residual_minor BIGINT NOT NULL CHECK(rounding_residual_minor>=0),
 record_date DATE NOT NULL,payment_date DATE NOT NULL,allocation_formula TEXT NOT NULL CHECK(allocation_formula='proportional_paid_units_v1'),withholding_rule JSONB NOT NULL CHECK(jsonb_typeof(withholding_rule)='object'),created_by UUID REFERENCES users(id) ON DELETE SET NULL,
 idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),calculated_at TIMESTAMPTZ NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,distribution_key),UNIQUE(organization_id,idempotency_key),CHECK(allocated_minor+rounding_residual_minor=distributable_minor),CHECK(payment_date>=record_date)
);
CREATE TABLE dividend_entitlements(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),distribution_id UUID NOT NULL REFERENCES dividend_distributions(id) ON DELETE RESTRICT,organization_id UUID NOT NULL REFERENCES organizations(id),member_id UUID NOT NULL REFERENCES users(id),
 paid_units BIGINT NOT NULL CHECK(paid_units>0),gross_minor BIGINT NOT NULL CHECK(gross_minor>=0),created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),UNIQUE(distribution_id,member_id)
);
CREATE OR REPLACE FUNCTION protect_dividend_snapshot() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$ BEGIN RAISE EXCEPTION 'DIVIDEND_SNAPSHOT_IMMUTABLE'; END $$;
CREATE TRIGGER dividend_distributions_immutable BEFORE UPDATE OR DELETE ON dividend_distributions FOR EACH ROW EXECUTE FUNCTION protect_dividend_snapshot();
CREATE TRIGGER dividend_entitlements_immutable BEFORE UPDATE OR DELETE ON dividend_entitlements FOR EACH ROW EXECUTE FUNCTION protect_dividend_snapshot();
CREATE OR REPLACE FUNCTION calculate_dividend_entitlement_snapshot(p_organization UUID,p_actor UUID,p_source_period UUID,p_distribution_key TEXT,p_currency TEXT,p_distributable_minor BIGINT,p_retained_reserve_minor BIGINT,p_record_date DATE,p_payment_date DATE,p_withholding_rule JSONB,p_eligibility JSONB,p_idempotency_key TEXT,p_calculated_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; old dividend_distributions; distribution_id UUID; total_units BIGINT; allocated BIGINT; cur TEXT:=upper(p_currency); h TEXT; item JSONB;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.post') THEN RAISE EXCEPTION 'DIVIDEND_CALCULATION_PERMISSION_DENIED'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE id=p_source_period AND organization_id=p_organization;
 IF period.id IS NULL OR p_distribution_key IS NULL OR p_distribution_key!~'^[a-z][a-z0-9_-]{1,47}$' OR cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_distributable_minor IS NULL OR p_distributable_minor<=0 OR p_retained_reserve_minor IS NULL OR p_retained_reserve_minor<0 OR p_record_date IS NULL OR p_record_date NOT BETWEEN period.starts_on AND period.ends_on OR p_payment_date IS NULL OR p_payment_date<p_record_date OR p_withholding_rule IS NULL OR jsonb_typeof(p_withholding_rule)<>'object' OR p_eligibility IS NULL OR jsonb_typeof(p_eligibility)<>'array' OR jsonb_array_length(p_eligibility)=0 OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_calculated_at IS NULL OR p_calculated_at>clock_timestamp() THEN RAISE EXCEPTION 'DIVIDEND_CALCULATION_REQUEST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_eligibility) value WHERE NOT(value?'member_id' AND value?'paid_units') OR (value->>'paid_units')::BIGINT<=0) OR (SELECT count(*) FROM jsonb_array_elements(p_eligibility))<>(SELECT count(DISTINCT value->>'member_id') FROM jsonb_array_elements(p_eligibility) value) THEN RAISE EXCEPTION 'DIVIDEND_ELIGIBILITY_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_eligibility) value WHERE NOT EXISTS(SELECT 1 FROM organization_memberships membership WHERE membership.organization_id=p_organization AND membership.user_id=(value->>'member_id')::UUID AND membership.status='active' AND membership.joined_at::DATE<=p_record_date)) THEN RAISE EXCEPTION 'DIVIDEND_ELIGIBILITY_INVALID'; END IF;
 SELECT sum((value->>'paid_units')::BIGINT)::BIGINT INTO total_units FROM jsonb_array_elements(p_eligibility) value;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_source_period,p_distribution_key,cur,p_distributable_minor,p_retained_reserve_minor,p_record_date,p_payment_date,p_withholding_rule::TEXT,p_eligibility::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':dividend:'||p_idempotency_key,0));
 SELECT * INTO old FROM dividend_distributions WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'DIVIDEND_IDEMPOTENCY_CONFLICT'; END IF; RETURN old.id; END IF;
 SELECT COALESCE(sum((p_distributable_minor*(value->>'paid_units')::BIGINT)/total_units),0)::BIGINT INTO allocated FROM jsonb_array_elements(p_eligibility) value;
 INSERT INTO dividend_distributions(organization_id,source_period_id,distribution_key,currency,distributable_minor,retained_reserve_minor,eligible_units,allocated_minor,rounding_residual_minor,record_date,payment_date,allocation_formula,withholding_rule,created_by,idempotency_key,request_hash,calculated_at) VALUES(p_organization,p_source_period,p_distribution_key,cur,p_distributable_minor,p_retained_reserve_minor,total_units,allocated,p_distributable_minor-allocated,p_record_date,p_payment_date,'proportional_paid_units_v1',p_withholding_rule,p_actor,p_idempotency_key,h,p_calculated_at) RETURNING id INTO distribution_id;
 FOR item IN SELECT value FROM jsonb_array_elements(p_eligibility) LOOP INSERT INTO dividend_entitlements(distribution_id,organization_id,member_id,paid_units,gross_minor) VALUES(distribution_id,p_organization,(item->>'member_id')::UUID,(item->>'paid_units')::BIGINT,(p_distributable_minor*(item->>'paid_units')::BIGINT)/total_units); END LOOP;
 RETURN distribution_id;
END $$;
REVOKE ALL ON dividend_distributions,dividend_entitlements FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON dividend_distributions,dividend_entitlements TO service_role;
REVOKE ALL ON FUNCTION calculate_dividend_entitlement_snapshot(UUID,UUID,UUID,TEXT,TEXT,BIGINT,BIGINT,DATE,DATE,JSONB,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION calculate_dividend_entitlement_snapshot(UUID,UUID,UUID,TEXT,TEXT,BIGINT,BIGINT,DATE,DATE,JSONB,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
