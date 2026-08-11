-- CRD-01: versioned, tenant-scoped loan products with immutable disclosures,
-- complete rule snapshots, idempotency, and maker-checker activation.

CREATE OR REPLACE FUNCTION valid_loan_fee_rules(p_rules JSONB) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_typeof(p_rules) = 'array'
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_rules) fee
      WHERE jsonb_typeof(fee) <> 'object'
        OR COALESCE(fee->>'code','') !~ '^[a-z][a-z0-9_]{1,39}$'
        OR length(btrim(COALESCE(fee->>'label',''))) NOT BETWEEN 2 AND 120
        OR COALESCE(fee->>'calculation','') NOT IN ('fixed','percentage')
        OR COALESCE(fee->>'timing','') NOT IN ('application','disbursement','repayment','delinquency')
        OR jsonb_typeof(fee->'capitalized') <> 'boolean'
        OR (fee->>'calculation' = 'fixed' AND (
          COALESCE(fee->>'amountMinor','') !~ '^[1-9][0-9]*$' OR fee ? 'rateBasisPoints'
        ))
        OR (fee->>'calculation' = 'percentage' AND (
          COALESCE(fee->>'rateBasisPoints','') !~ '^[1-9][0-9]*$'
          OR (fee->>'rateBasisPoints')::BIGINT > 100000 OR fee ? 'amountMinor'
        ))
    )
    AND (SELECT count(*) = count(DISTINCT fee->>'code') FROM jsonb_array_elements(p_rules) fee);
$$;

CREATE OR REPLACE FUNCTION valid_loan_delinquency_stages(p_rules JSONB) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_typeof(p_rules) = 'array'
    AND jsonb_array_length(p_rules) > 0
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_rules) stage
      WHERE jsonb_typeof(stage) <> 'object'
        OR COALESCE(stage->>'code','') !~ '^[a-z][a-z0-9_]{1,39}$'
        OR length(btrim(COALESCE(stage->>'label',''))) NOT BETWEEN 2 AND 120
        OR COALESCE(stage->>'startsAfterDays','') !~ '^[0-9]+$'
        OR COALESCE(stage->>'classification','') NOT IN ('late','delinquent','defaulted')
    )
    AND (SELECT count(*) = count(DISTINCT stage->>'code') FROM jsonb_array_elements(p_rules) stage)
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_rules) WITH ORDINALITY current_stage(value, position)
      JOIN jsonb_array_elements(p_rules) WITH ORDINALITY prior_stage(value, position)
        ON prior_stage.position = current_stage.position - 1
      WHERE (current_stage.value->>'startsAfterDays')::BIGINT
        <= (prior_stage.value->>'startsAfterDays')::BIGINT
    );
$$;

CREATE TABLE loan_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  code TEXT NOT NULL CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 160),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','pending_approval','active','retired')),
  current_version INTEGER NOT NULL DEFAULT 0 CHECK (current_version >= 0),
  created_by UUID NOT NULL REFERENCES users(id),
  creation_key TEXT NOT NULL CHECK (length(creation_key) BETWEEN 8 AND 160),
  creation_hash VARCHAR(64) NOT NULL CHECK (creation_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, code),
  UNIQUE (organization_id, creation_key),
  UNIQUE (id, organization_id)
);

CREATE TABLE loan_product_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  product_id UUID NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','pending_approval','active','retired')),
  lender_type TEXT NOT NULL CHECK (lender_type IN ('organization','licensed_provider','partner')),
  lender_name TEXT NOT NULL CHECK (length(btrim(lender_name)) BETWEEN 2 AND 160),
  provider_code TEXT CHECK (provider_code IS NULL OR provider_code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  eligible_borrower_types TEXT[] NOT NULL CHECK (
    cardinality(eligible_borrower_types) > 0
    AND eligible_borrower_types <@ ARRAY['individual','group','organization']::TEXT[]
  ),
  purposes TEXT[] NOT NULL CHECK (cardinality(purposes) > 0),
  minimum_principal_minor BIGINT NOT NULL CHECK (minimum_principal_minor > 0),
  maximum_principal_minor BIGINT NOT NULL CHECK (maximum_principal_minor >= minimum_principal_minor),
  minimum_tenor_days INTEGER NOT NULL CHECK (minimum_tenor_days > 0),
  maximum_tenor_days INTEGER NOT NULL CHECK (maximum_tenor_days >= minimum_tenor_days),
  repayment_frequency TEXT NOT NULL CHECK (repayment_frequency IN ('weekly','fortnightly','monthly','quarterly','bullet')),
  interest_method TEXT NOT NULL CHECK (interest_method IN ('reducing_balance','flat','simple','zero_interest')),
  nominal_annual_rate_basis_points INTEGER NOT NULL CHECK (nominal_annual_rate_basis_points BETWEEN 0 AND 100000),
  apr_basis_points INTEGER NOT NULL CHECK (apr_basis_points BETWEEN nominal_annual_rate_basis_points AND 100000),
  effective_annual_cost_basis_points INTEGER NOT NULL CHECK (effective_annual_cost_basis_points BETWEEN apr_basis_points AND 100000),
  fees JSONB NOT NULL DEFAULT '[]'::JSONB CHECK (valid_loan_fee_rules(fees)),
  grace_period_days INTEGER NOT NULL CHECK (grace_period_days >= 0),
  collateral_rules JSONB NOT NULL CHECK (jsonb_typeof(collateral_rules) = 'object'),
  guarantee_rules JSONB NOT NULL CHECK (jsonb_typeof(guarantee_rules) = 'object'),
  affordability_rules JSONB NOT NULL CHECK (jsonb_typeof(affordability_rules) = 'object'),
  delinquency_stages JSONB NOT NULL CHECK (valid_loan_delinquency_stages(delinquency_stages)),
  restructuring_policy JSONB NOT NULL CHECK (jsonb_typeof(restructuring_policy) = 'object'),
  write_off_policy JSONB NOT NULL CHECK (jsonb_typeof(write_off_policy) = 'object'),
  repayment_allocation_order TEXT[] NOT NULL CHECK (
    cardinality(repayment_allocation_order) = 5
    AND repayment_allocation_order @> ARRAY['statutory_charges','collection_costs','penalties','accrued_interest','principal']::TEXT[]
  ),
  penalty_compounding_allowed BOOLEAN NOT NULL DEFAULT FALSE,
  penalty_compounding_legal_basis TEXT,
  disclosure_version TEXT NOT NULL CHECK (length(btrim(disclosure_version)) BETWEEN 1 AND 80),
  disclosure_content_hash VARCHAR(64) NOT NULL CHECK (disclosure_content_hash ~ '^[a-f0-9]{64}$'),
  created_by UUID NOT NULL REFERENCES users(id),
  submitted_at TIMESTAMPTZ,
  approved_by UUID REFERENCES users(id),
  approved_at TIMESTAMPTZ,
  effective_from TIMESTAMPTZ,
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (product_id, organization_id) REFERENCES loan_products(id, organization_id),
  UNIQUE (organization_id, product_id, version),
  UNIQUE (id, organization_id),
  CHECK ((lender_type = 'organization') OR provider_code IS NOT NULL),
  CHECK ((interest_method = 'zero_interest') = (nominal_annual_rate_basis_points = 0)),
  CHECK ((penalty_compounding_allowed AND length(btrim(penalty_compounding_legal_basis)) BETWEEN 12 AND 500)
    OR (NOT penalty_compounding_allowed AND penalty_compounding_legal_basis IS NULL)),
  CHECK ((state = 'active' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND effective_from IS NOT NULL)
    OR state <> 'active'),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
CREATE UNIQUE INDEX uq_active_loan_product_version
  ON loan_product_versions(organization_id, product_id) WHERE state = 'active';
CREATE UNIQUE INDEX uq_open_loan_product_version
  ON loan_product_versions(organization_id, product_id) WHERE state IN ('draft','pending_approval');

CREATE TABLE loan_product_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  product_id UUID NOT NULL,
  product_version_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('product_created','revision_created','submitted','approved')),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (product_id, organization_id) REFERENCES loan_products(id, organization_id),
  FOREIGN KEY (product_version_id, organization_id) REFERENCES loan_product_versions(id, organization_id),
  UNIQUE (organization_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION require_loan_product_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.loan_product_engine', TRUE) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'LOAN_PRODUCT_ENGINE_REQUIRED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER loan_products_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_products
  FOR EACH ROW EXECUTE FUNCTION require_loan_product_engine();
CREATE TRIGGER loan_product_versions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_product_versions
  FOR EACH ROW EXECUTE FUNCTION require_loan_product_engine();
CREATE TRIGGER loan_product_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON loan_product_events
  FOR EACH ROW EXECUTE FUNCTION require_loan_product_engine();

CREATE OR REPLACE FUNCTION validate_loan_product_facts(p_facts JSONB) RETURNS VOID
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE v_borrowers TEXT[]; v_purposes TEXT[]; v_allocation TEXT[];
BEGIN
  IF jsonb_typeof(p_facts) <> 'object' THEN RAISE EXCEPTION 'Loan product facts must be an object'; END IF;
  IF COALESCE(p_facts->>'lenderType','') NOT IN ('organization','licensed_provider','partner')
    OR length(btrim(COALESCE(p_facts->>'lenderName',''))) NOT BETWEEN 2 AND 160
  THEN RAISE EXCEPTION 'Lender configuration is invalid'; END IF;
  IF p_facts->>'lenderType' <> 'organization' AND COALESCE(p_facts->>'providerCode','') !~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'
  THEN RAISE EXCEPTION 'External lender products require a provider code'; END IF;
  IF p_facts->>'providerCode' IS NOT NULL AND p_facts->>'providerCode' !~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'
  THEN RAISE EXCEPTION 'Provider code is invalid'; END IF;
  IF jsonb_typeof(p_facts->'eligibleBorrowerTypes') <> 'array' OR jsonb_array_length(p_facts->'eligibleBorrowerTypes') = 0
    OR jsonb_typeof(p_facts->'purposes') <> 'array' OR jsonb_array_length(p_facts->'purposes') = 0
  THEN RAISE EXCEPTION 'Borrower types and purposes are required'; END IF;
  SELECT array_agg(value) INTO v_borrowers FROM jsonb_array_elements_text(p_facts->'eligibleBorrowerTypes');
  SELECT array_agg(value) INTO v_purposes FROM jsonb_array_elements_text(p_facts->'purposes');
  IF NOT v_borrowers <@ ARRAY['individual','group','organization']::TEXT[]
    OR cardinality(v_borrowers) <> (SELECT count(DISTINCT value) FROM unnest(v_borrowers) value)
    OR EXISTS(SELECT 1 FROM unnest(v_purposes) purpose WHERE purpose !~ '^[a-z][a-z0-9_]{1,39}$')
    OR cardinality(v_purposes) <> (SELECT count(DISTINCT value) FROM unnest(v_purposes) value)
  THEN RAISE EXCEPTION 'Borrower types or purposes are invalid'; END IF;
  IF COALESCE(p_facts->>'minimumPrincipalMinor','') !~ '^[1-9][0-9]*$'
    OR COALESCE(p_facts->>'maximumPrincipalMinor','') !~ '^[1-9][0-9]*$'
    OR (p_facts->>'maximumPrincipalMinor')::BIGINT < (p_facts->>'minimumPrincipalMinor')::BIGINT
  THEN RAISE EXCEPTION 'Principal limits are invalid'; END IF;
  IF COALESCE(p_facts->>'minimumTenorDays','') !~ '^[1-9][0-9]*$'
    OR COALESCE(p_facts->>'maximumTenorDays','') !~ '^[1-9][0-9]*$'
    OR (p_facts->>'maximumTenorDays')::INTEGER < (p_facts->>'minimumTenorDays')::INTEGER
  THEN RAISE EXCEPTION 'Tenor limits are invalid'; END IF;
  IF COALESCE(p_facts->>'repaymentFrequency','') NOT IN ('weekly','fortnightly','monthly','quarterly','bullet')
    OR COALESCE(p_facts->>'interestMethod','') NOT IN ('reducing_balance','flat','simple','zero_interest')
  THEN RAISE EXCEPTION 'Repayment or interest method is invalid'; END IF;
  IF COALESCE(p_facts->>'nominalAnnualRateBasisPoints','') !~ '^[0-9]+$'
    OR COALESCE(p_facts->>'aprBasisPoints','') !~ '^[0-9]+$'
    OR COALESCE(p_facts->>'effectiveAnnualCostBasisPoints','') !~ '^[0-9]+$'
    OR (p_facts->>'nominalAnnualRateBasisPoints')::INTEGER > 100000
    OR (p_facts->>'aprBasisPoints')::INTEGER NOT BETWEEN (p_facts->>'nominalAnnualRateBasisPoints')::INTEGER AND 100000
    OR (p_facts->>'effectiveAnnualCostBasisPoints')::INTEGER NOT BETWEEN (p_facts->>'aprBasisPoints')::INTEGER AND 100000
    OR ((p_facts->>'interestMethod' = 'zero_interest') <> ((p_facts->>'nominalAnnualRateBasisPoints')::INTEGER = 0))
  THEN RAISE EXCEPTION 'Interest and cost disclosures are invalid'; END IF;
  IF NOT valid_loan_fee_rules(p_facts->'fees') THEN RAISE EXCEPTION 'Fee rules are invalid'; END IF;
  IF COALESCE(p_facts->>'gracePeriodDays','') !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Grace period is invalid'; END IF;
  IF jsonb_typeof(p_facts->'collateralRules') <> 'object'
    OR jsonb_typeof(p_facts->'guaranteeRules') <> 'object'
    OR jsonb_typeof(p_facts->'affordabilityRules') <> 'object'
    OR jsonb_typeof(p_facts->'restructuringPolicy') <> 'object'
    OR jsonb_typeof(p_facts->'writeOffPolicy') <> 'object'
  THEN RAISE EXCEPTION 'Loan policy rules must be objects'; END IF;
  IF NOT valid_loan_delinquency_stages(p_facts->'delinquencyStages') THEN RAISE EXCEPTION 'Delinquency stages are invalid'; END IF;
  IF jsonb_typeof(p_facts->'repaymentAllocationOrder') <> 'array' THEN RAISE EXCEPTION 'Repayment allocation order is invalid'; END IF;
  SELECT array_agg(value) INTO v_allocation FROM jsonb_array_elements_text(p_facts->'repaymentAllocationOrder');
  IF cardinality(v_allocation) <> 5 OR NOT v_allocation @> ARRAY['statutory_charges','collection_costs','penalties','accrued_interest','principal']::TEXT[]
  THEN RAISE EXCEPTION 'Repayment allocation order is incomplete'; END IF;
  IF jsonb_typeof(p_facts->'penaltyCompoundingAllowed') <> 'boolean'
    OR ((p_facts->>'penaltyCompoundingAllowed')::BOOLEAN AND length(btrim(COALESCE(p_facts->>'penaltyCompoundingLegalBasis',''))) NOT BETWEEN 12 AND 500)
    OR (NOT (p_facts->>'penaltyCompoundingAllowed')::BOOLEAN AND p_facts->>'penaltyCompoundingLegalBasis' IS NOT NULL)
  THEN RAISE EXCEPTION 'Penalty compounding configuration is invalid'; END IF;
  IF length(btrim(COALESCE(p_facts->>'disclosureVersion',''))) NOT BETWEEN 1 AND 80
    OR COALESCE(p_facts->>'disclosureContentHash','') !~ '^[a-f0-9]{64}$'
  THEN RAISE EXCEPTION 'Disclosure evidence is invalid'; END IF;
END $$;

CREATE OR REPLACE FUNCTION insert_loan_product_version(
  p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,p_facts JSONB,p_at TIMESTAMPTZ
) RETURNS loan_product_versions LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v loan_product_versions;
BEGIN
  PERFORM validate_loan_product_facts(p_facts);
  INSERT INTO loan_product_versions(organization_id,product_id,version,lender_type,lender_name,provider_code,
    eligible_borrower_types,purposes,minimum_principal_minor,maximum_principal_minor,minimum_tenor_days,maximum_tenor_days,
    repayment_frequency,interest_method,nominal_annual_rate_basis_points,apr_basis_points,effective_annual_cost_basis_points,
    fees,grace_period_days,collateral_rules,guarantee_rules,affordability_rules,delinquency_stages,restructuring_policy,
    write_off_policy,repayment_allocation_order,penalty_compounding_allowed,penalty_compounding_legal_basis,
    disclosure_version,disclosure_content_hash,created_by,created_at)
  VALUES(p_organization,p_product,p_version,p_facts->>'lenderType',btrim(p_facts->>'lenderName'),NULLIF(p_facts->>'providerCode',''),
    ARRAY(SELECT jsonb_array_elements_text(p_facts->'eligibleBorrowerTypes')),
    ARRAY(SELECT jsonb_array_elements_text(p_facts->'purposes')),
    (p_facts->>'minimumPrincipalMinor')::BIGINT,(p_facts->>'maximumPrincipalMinor')::BIGINT,
    (p_facts->>'minimumTenorDays')::INTEGER,(p_facts->>'maximumTenorDays')::INTEGER,
    p_facts->>'repaymentFrequency',p_facts->>'interestMethod',(p_facts->>'nominalAnnualRateBasisPoints')::INTEGER,
    (p_facts->>'aprBasisPoints')::INTEGER,(p_facts->>'effectiveAnnualCostBasisPoints')::INTEGER,p_facts->'fees',
    (p_facts->>'gracePeriodDays')::INTEGER,p_facts->'collateralRules',p_facts->'guaranteeRules',p_facts->'affordabilityRules',
    p_facts->'delinquencyStages',p_facts->'restructuringPolicy',p_facts->'writeOffPolicy',
    ARRAY(SELECT jsonb_array_elements_text(p_facts->'repaymentAllocationOrder')),
    (p_facts->>'penaltyCompoundingAllowed')::BOOLEAN,NULLIF(p_facts->>'penaltyCompoundingLegalBasis',''),
    btrim(p_facts->>'disclosureVersion'),p_facts->>'disclosureContentHash',p_actor,p_at)
  RETURNING * INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION create_loan_product_draft(
  p_organization UUID,p_actor UUID,p_code TEXT,p_name TEXT,p_currency TEXT,p_facts JSONB,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product loan_products; v_version loan_product_versions; v_event loan_product_events; v_hash TEXT; v_currency TEXT:=upper(p_currency);
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.configure') THEN RAISE EXCEPTION 'Missing financial.loans.configure permission'; END IF;
  IF p_code IS NULL OR upper(p_code) !~ '^[A-Z0-9][A-Z0-9._-]{1,39}$' THEN RAISE EXCEPTION 'Loan product code is invalid'; END IF;
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Loan product name is invalid'; END IF;
  IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'Currency must be a three-letter ISO code'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
  PERFORM validate_loan_product_facts(p_facts);
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,upper(p_code),btrim(p_name),v_currency,p_facts::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-product:'||p_idempotency_key,0));
  SELECT * INTO v_event FROM loan_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different loan product facts'; END IF;
    SELECT * INTO v_product FROM loan_products WHERE id=v_event.product_id;
    SELECT * INTO v_version FROM loan_product_versions WHERE id=v_event.product_version_id;
    RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
  END IF;
  PERFORM set_config('microfams.loan_product_engine','on',TRUE);
  INSERT INTO loan_products(organization_id,code,name,currency,created_by,creation_key,creation_hash,created_at,updated_at)
    VALUES(p_organization,upper(p_code),btrim(p_name),v_currency,p_actor,p_idempotency_key,v_hash,p_at,p_at) RETURNING * INTO v_product;
  v_version:=insert_loan_product_version(p_organization,p_actor,v_product.id,1,p_facts,p_at);
  INSERT INTO loan_product_events(organization_id,product_id,product_version_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,v_product.id,v_version.id,'product_created',p_actor,p_idempotency_key,v_hash,
      jsonb_build_object('version',1,'disclosure_version',v_version.disclosure_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'LOAN_PRODUCT_DRAFTED','loan_product',v_product.id::TEXT,
      jsonb_build_object('code',v_product.code,'currency',v_product.currency,'version',1,'disclosure_version',v_version.disclosure_version),p_at);
  RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
END $$;

CREATE OR REPLACE FUNCTION revise_loan_product(
  p_organization UUID,p_actor UUID,p_product UUID,p_expected_current_version INTEGER,p_facts JSONB,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product loan_products; v_version loan_product_versions; v_event loan_product_events; v_hash TEXT; v_next INTEGER;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.configure') THEN RAISE EXCEPTION 'Missing financial.loans.configure permission'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
  PERFORM validate_loan_product_facts(p_facts);
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_expected_current_version::TEXT,p_facts::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-product:'||p_product::TEXT,0));
  SELECT * INTO v_event FROM loan_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different revision facts'; END IF;
    SELECT * INTO v_product FROM loan_products WHERE id=v_event.product_id;
    SELECT * INTO v_version FROM loan_product_versions WHERE id=v_event.product_version_id;
    RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
  END IF;
  SELECT * INTO v_product FROM loan_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
  IF v_product.id IS NULL OR v_product.state<>'active' OR v_product.current_version<>p_expected_current_version THEN
    RAISE EXCEPTION 'Active loan product is not at the expected version';
  END IF;
  IF EXISTS(SELECT 1 FROM loan_product_versions WHERE product_id=p_product AND organization_id=p_organization AND state IN ('draft','pending_approval')) THEN
    RAISE EXCEPTION 'Loan product already has an open revision';
  END IF;
  v_next:=v_product.current_version+1;
  PERFORM set_config('microfams.loan_product_engine','on',TRUE);
  v_version:=insert_loan_product_version(p_organization,p_actor,p_product,v_next,p_facts,p_at);
  INSERT INTO loan_product_events(organization_id,product_id,product_version_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,v_version.id,'revision_created',p_actor,p_idempotency_key,v_hash,
      jsonb_build_object('version',v_next,'replaces_version',p_expected_current_version,'disclosure_version',v_version.disclosure_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'LOAN_PRODUCT_REVISION_DRAFTED','loan_product',p_product::TEXT,
      jsonb_build_object('version',v_next,'replaces_version',p_expected_current_version,'disclosure_version',v_version.disclosure_version),p_at);
  RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
END $$;

CREATE OR REPLACE FUNCTION submit_loan_product_version(
  p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product loan_products; v_version loan_product_versions; v_event loan_product_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.configure') THEN RAISE EXCEPTION 'Missing financial.loans.configure permission'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_version::TEXT,'submit'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-product:'||p_product::TEXT,0));
  SELECT * INTO v_event FROM loan_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different command facts'; END IF;
    SELECT * INTO v_version FROM loan_product_versions WHERE id=v_event.product_version_id; RETURN to_jsonb(v_version); END IF;
  SELECT * INTO v_product FROM loan_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_version FROM loan_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_version FOR UPDATE;
  IF v_product.id IS NULL OR v_version.id IS NULL OR v_version.state<>'draft' THEN RAISE EXCEPTION 'Loan product version is not an expected draft'; END IF;
  IF p_version=1 AND (v_product.state<>'draft' OR v_product.current_version<>0) THEN RAISE EXCEPTION 'Initial loan product is not a draft'; END IF;
  IF p_version>1 AND (v_product.state<>'active' OR v_product.current_version<>p_version-1) THEN RAISE EXCEPTION 'Loan product revision is stale'; END IF;
  PERFORM set_config('microfams.loan_product_engine','on',TRUE);
  UPDATE loan_product_versions SET state='pending_approval',submitted_at=p_at WHERE id=v_version.id RETURNING * INTO v_version;
  IF p_version=1 THEN UPDATE loan_products SET state='pending_approval',updated_at=p_at WHERE id=p_product; END IF;
  INSERT INTO loan_product_events(organization_id,product_id,product_version_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,v_version.id,'submitted',p_actor,p_idempotency_key,v_hash,jsonb_build_object('version',p_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'LOAN_PRODUCT_SUBMITTED','loan_product',p_product::TEXT,jsonb_build_object('version',p_version),p_at);
  RETURN to_jsonb(v_version);
END $$;

CREATE OR REPLACE FUNCTION approve_loan_product_version(
  p_organization UUID,p_actor UUID,p_product UUID,p_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product loan_products; v_version loan_product_versions; v_event loan_product_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.configure') THEN RAISE EXCEPTION 'Missing financial.loans.configure permission'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_version::TEXT,'approve'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':loan-product:'||p_product::TEXT,0));
  SELECT * INTO v_event FROM loan_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different command facts'; END IF;
    SELECT * INTO v_version FROM loan_product_versions WHERE id=v_event.product_version_id; RETURN to_jsonb(v_version); END IF;
  SELECT * INTO v_product FROM loan_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_version FROM loan_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_version FOR UPDATE;
  IF v_product.id IS NULL OR v_version.id IS NULL OR v_version.state<>'pending_approval' THEN RAISE EXCEPTION 'Loan product version is not pending approval'; END IF;
  IF v_version.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own loan product version'; END IF;
  IF p_version=1 AND v_product.state<>'pending_approval' THEN RAISE EXCEPTION 'Initial loan product is not pending approval'; END IF;
  IF p_version>1 AND (v_product.state<>'active' OR v_product.current_version<>p_version-1) THEN RAISE EXCEPTION 'Loan product revision is stale'; END IF;
  PERFORM set_config('microfams.loan_product_engine','on',TRUE);
  UPDATE loan_product_versions SET state='retired',retired_at=p_at WHERE product_id=p_product AND organization_id=p_organization AND state='active';
  UPDATE loan_product_versions SET state='active',approved_by=p_actor,approved_at=p_at,effective_from=p_at WHERE id=v_version.id RETURNING * INTO v_version;
  UPDATE loan_products SET state='active',current_version=p_version,updated_at=p_at WHERE id=p_product RETURNING * INTO v_product;
  INSERT INTO loan_product_events(organization_id,product_id,product_version_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,v_version.id,'approved',p_actor,p_idempotency_key,v_hash,
      jsonb_build_object('version',p_version,'disclosure_version',v_version.disclosure_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'LOAN_PRODUCT_APPROVED','loan_product',p_product::TEXT,
      jsonb_build_object('version',p_version,'disclosure_version',v_version.disclosure_version,'approved_by',p_actor),p_at);
  RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
END $$;

CREATE OR REPLACE FUNCTION list_active_loan_products(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN
    RAISE EXCEPTION 'Actor is not an active organization member';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v)) ORDER BY p.name)
    FROM loan_products p JOIN loan_product_versions v ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.version=p.current_version
    WHERE p.organization_id=p_organization AND p.state='active' AND v.state='active'),'[]'::JSONB);
END $$;

CREATE OR REPLACE FUNCTION list_governed_loan_products(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.configure') THEN RAISE EXCEPTION 'Missing financial.loans.configure permission'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('product',to_jsonb(p),'versions',(
      SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.version DESC),'[]'::JSONB)
      FROM loan_product_versions v WHERE v.organization_id=p.organization_id AND v.product_id=p.id
    )) ORDER BY p.name) FROM loan_products p WHERE p.organization_id=p_organization),'[]'::JSONB);
END $$;

INSERT INTO feature_flags(key,domain,description,default_enabled,failure_mode,risk) VALUES
  ('financial.loans.read','loans','Read active loan products and existing credit records.',TRUE,'open','regulated'),
  ('financial.loans.configure','loans','Draft, revise, submit, and independently approve loan products.',FALSE,'closed','regulated')
ON CONFLICT(key) DO UPDATE SET domain=EXCLUDED.domain,description=EXCLUDED.description,
  default_enabled=EXCLUDED.default_enabled,failure_mode=EXCLUDED.failure_mode,risk=EXCLUDED.risk,updated_at=NOW();

UPDATE organization_memberships SET permissions=ARRAY(
  SELECT DISTINCT permission FROM unnest(COALESCE(permissions,'{}')||ARRAY['financial.loans.configure']) permission
) WHERE role='owner';

CREATE OR REPLACE FUNCTION provision_loan_owner_permission() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.role='owner' AND NOT ('financial.loans.configure'=ANY(COALESCE(NEW.permissions,'{}'))) THEN
    NEW.permissions:=array_append(COALESCE(NEW.permissions,'{}'),'financial.loans.configure');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER provision_loan_owner_permission_trigger
  BEFORE INSERT OR UPDATE OF role,permissions ON organization_memberships
  FOR EACH ROW EXECUTE FUNCTION provision_loan_owner_permission();

ALTER TABLE loan_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_product_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_product_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON loan_products,loan_product_versions,loan_product_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON loan_products,loan_product_versions,loan_product_events FROM service_role;
GRANT SELECT ON loan_products,loan_product_versions,loan_product_events TO service_role;
REVOKE ALL ON FUNCTION valid_loan_fee_rules(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION valid_loan_delinquency_stages(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION validate_loan_product_facts(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION insert_loan_product_version(UUID,UUID,UUID,INTEGER,JSONB,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_loan_product_draft(UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION revise_loan_product(UUID,UUID,UUID,INTEGER,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_loan_product_version(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_loan_product_version(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_active_loan_products(UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_governed_loan_products(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_loan_product_draft(UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION revise_loan_product(UUID,UUID,UUID,INTEGER,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION submit_loan_product_version(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION approve_loan_product_version(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_active_loan_products(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION list_governed_loan_products(UUID,UUID) TO service_role;
