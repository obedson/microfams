-- Approved savings-product foundation: governed products, immutable disclosures,
-- maker-checker activation, tenant isolation, and disclosure-bound enrolment.

CREATE TABLE savings_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  code TEXT NOT NULL CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{1,39}$'),
  name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 160),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','pending_approval','active','retired')),
  current_version INTEGER NOT NULL DEFAULT 1 CHECK (current_version > 0),
  created_by UUID NOT NULL REFERENCES users(id),
  creation_key TEXT NOT NULL CHECK (length(creation_key) BETWEEN 8 AND 160),
  creation_hash VARCHAR(64) NOT NULL CHECK (creation_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, code),
  UNIQUE (organization_id, creation_key),
  UNIQUE (id, organization_id)
);

CREATE TABLE savings_product_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  product_id UUID NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','pending_approval','active','retired')),
  minimum_contribution_minor BIGINT NOT NULL CHECK (minimum_contribution_minor > 0),
  maximum_contribution_minor BIGINT NOT NULL CHECK (maximum_contribution_minor >= minimum_contribution_minor),
  contribution_frequency TEXT NOT NULL CHECK (contribution_frequency IN ('manual','daily','weekly','monthly','quarterly')),
  default_target_minor BIGINT CHECK (default_target_minor IS NULL OR default_target_minor >= minimum_contribution_minor),
  lock_period_days INTEGER NOT NULL CHECK (lock_period_days >= 0),
  grace_period_days INTEGER NOT NULL CHECK (grace_period_days >= 0),
  early_withdrawal_rule TEXT NOT NULL CHECK (early_withdrawal_rule IN ('blocked','allowed','forfeit_returns','fee')),
  early_withdrawal_fee_minor BIGINT NOT NULL DEFAULT 0 CHECK (early_withdrawal_fee_minor >= 0),
  return_method TEXT NOT NULL CHECK (return_method IN ('none','simple_interest')),
  annual_rate_basis_points INTEGER NOT NULL DEFAULT 0 CHECK (annual_rate_basis_points BETWEEN 0 AND 100000),
  day_count_convention TEXT NOT NULL CHECK (day_count_convention IN ('actual_365','actual_360')),
  disclosure_version TEXT NOT NULL CHECK (length(btrim(disclosure_version)) BETWEEN 1 AND 80),
  disclosure_content_hash VARCHAR(64) NOT NULL CHECK (disclosure_content_hash ~ '^[a-f0-9]{64}$'),
  eligibility JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(eligibility) = 'object'),
  created_by UUID NOT NULL REFERENCES users(id),
  approved_by UUID REFERENCES users(id),
  submitted_at TIMESTAMPTZ,
  approved_at TIMESTAMPTZ,
  effective_from TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (product_id, organization_id) REFERENCES savings_products(id, organization_id),
  UNIQUE (organization_id, product_id, version),
  UNIQUE (id, organization_id),
  CHECK ((early_withdrawal_rule = 'fee') = (early_withdrawal_fee_minor > 0)),
  CHECK ((return_method = 'none' AND annual_rate_basis_points = 0)
      OR (return_method = 'simple_interest' AND annual_rate_basis_points > 0)),
  CHECK ((state = 'active' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND effective_from IS NOT NULL)
      OR state <> 'active'),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
CREATE UNIQUE INDEX uq_active_savings_product_version
  ON savings_product_versions(organization_id, product_id) WHERE state = 'active';

CREATE TABLE savings_enrolments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  product_id UUID NOT NULL,
  product_version_id UUID NOT NULL,
  member_id UUID NOT NULL REFERENCES users(id),
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','locked','closed','cancelled')),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  target_minor BIGINT CHECK (target_minor IS NULL OR target_minor > 0),
  accepted_disclosure_version TEXT NOT NULL,
  accepted_disclosure_hash VARCHAR(64) NOT NULL CHECK (accepted_disclosure_hash ~ '^[a-f0-9]{64}$'),
  accepted_at TIMESTAMPTZ NOT NULL,
  lock_expires_at TIMESTAMPTZ,
  principal_account_id UUID,
  accrued_return_account_id UUID,
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (product_id, organization_id) REFERENCES savings_products(id, organization_id),
  FOREIGN KEY (product_version_id, organization_id) REFERENCES savings_product_versions(id, organization_id),
  FOREIGN KEY (principal_account_id, organization_id, currency) REFERENCES financial_accounts(id, organization_id, currency),
  FOREIGN KEY (accrued_return_account_id, organization_id, currency) REFERENCES financial_accounts(id, organization_id, currency),
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (id, organization_id),
  CHECK ((principal_account_id IS NULL) = (accrued_return_account_id IS NULL))
);
CREATE INDEX idx_savings_enrolments_member
  ON savings_enrolments(organization_id, member_id, state, created_at DESC);

CREATE TABLE savings_product_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  product_id UUID NOT NULL,
  enrolment_id UUID,
  action TEXT NOT NULL CHECK (action IN ('product_created','submitted','approved','enrolled')),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (product_id, organization_id) REFERENCES savings_products(id, organization_id),
  FOREIGN KEY (enrolment_id, organization_id) REFERENCES savings_enrolments(id, organization_id),
  UNIQUE (organization_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION require_savings_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('microfams.savings_engine', TRUE) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'SAVINGS_ENGINE_REQUIRED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER savings_products_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_products
  FOR EACH ROW EXECUTE FUNCTION require_savings_engine();
CREATE TRIGGER savings_product_versions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_product_versions
  FOR EACH ROW EXECUTE FUNCTION require_savings_engine();
CREATE TRIGGER savings_enrolments_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_enrolments
  FOR EACH ROW EXECUTE FUNCTION require_savings_engine();
CREATE TRIGGER savings_product_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_product_events
  FOR EACH ROW EXECUTE FUNCTION require_savings_engine();

CREATE OR REPLACE FUNCTION create_savings_product_draft(
  p_organization UUID, p_actor UUID, p_code TEXT, p_name TEXT, p_currency TEXT,
  p_minimum_minor BIGINT, p_maximum_minor BIGINT, p_frequency TEXT, p_default_target_minor BIGINT,
  p_lock_days INTEGER, p_grace_days INTEGER, p_early_rule TEXT, p_early_fee_minor BIGINT,
  p_return_method TEXT, p_annual_rate_bps INTEGER, p_day_count TEXT,
  p_disclosure_version TEXT, p_disclosure_hash TEXT, p_eligibility JSONB,
  p_idempotency_key TEXT, p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product savings_products; v_version savings_product_versions; v_hash TEXT; v_currency TEXT := upper(p_currency);
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
    RAISE EXCEPTION 'Missing financial.savings.configure permission';
  END IF;
  IF p_code IS NULL OR upper(p_code) !~ '^[A-Z0-9][A-Z0-9._-]{1,39}$' THEN RAISE EXCEPTION 'Savings product code is invalid'; END IF;
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Savings product name is invalid'; END IF;
  IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'Currency must be a three-letter ISO code'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
  IF p_eligibility IS NULL OR jsonb_typeof(p_eligibility) <> 'object' THEN RAISE EXCEPTION 'Eligibility must be an object'; END IF;
  v_hash := encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,upper(p_code),btrim(p_name),v_currency,
    p_minimum_minor::TEXT,p_maximum_minor::TEXT,p_frequency,COALESCE(p_default_target_minor::TEXT,''),p_lock_days::TEXT,p_grace_days::TEXT,
    p_early_rule,p_early_fee_minor::TEXT,p_return_method,p_annual_rate_bps::TEXT,p_day_count,p_disclosure_version,p_disclosure_hash,p_eligibility::TEXT),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-product:'||p_idempotency_key,0));
  SELECT * INTO v_product FROM savings_products WHERE organization_id=p_organization AND creation_key=p_idempotency_key;
  IF v_product.id IS NOT NULL THEN
    IF v_product.creation_hash <> v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different savings product facts'; END IF;
    SELECT * INTO v_version FROM savings_product_versions WHERE organization_id=p_organization AND product_id=v_product.id AND version=1;
    RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
  END IF;
  PERFORM set_config('microfams.savings_engine','on',TRUE);
  INSERT INTO savings_products(organization_id,code,name,currency,created_by,creation_key,creation_hash,created_at,updated_at)
    VALUES(p_organization,upper(p_code),btrim(p_name),v_currency,p_actor,p_idempotency_key,v_hash,p_at,p_at) RETURNING * INTO v_product;
  INSERT INTO savings_product_versions(organization_id,product_id,version,minimum_contribution_minor,maximum_contribution_minor,
    contribution_frequency,default_target_minor,lock_period_days,grace_period_days,early_withdrawal_rule,early_withdrawal_fee_minor,
    return_method,annual_rate_basis_points,day_count_convention,disclosure_version,disclosure_content_hash,eligibility,created_by,created_at)
    VALUES(p_organization,v_product.id,1,p_minimum_minor,p_maximum_minor,p_frequency,p_default_target_minor,p_lock_days,p_grace_days,
      p_early_rule,p_early_fee_minor,p_return_method,p_annual_rate_bps,p_day_count,btrim(p_disclosure_version),lower(p_disclosure_hash),p_eligibility,p_actor,p_at)
    RETURNING * INTO v_version;
  INSERT INTO savings_product_events(organization_id,product_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,v_product.id,'product_created',p_actor,p_idempotency_key,v_hash,jsonb_build_object('version',1),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'SAVINGS_PRODUCT_DRAFTED','savings_product',v_product.id::TEXT,
      jsonb_build_object('code',v_product.code,'currency',v_product.currency,'version',1,'disclosure_version',v_version.disclosure_version),p_at);
  RETURN jsonb_build_object('product',to_jsonb(v_product),'version',to_jsonb(v_version));
END $$;

CREATE OR REPLACE FUNCTION submit_savings_product(
  p_organization UUID,p_actor UUID,p_product UUID,p_expected_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product savings_products; v_version savings_product_versions; v_event savings_product_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN RAISE EXCEPTION 'Missing financial.savings.configure permission'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_expected_version::TEXT,'submit'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-product:'||p_product::TEXT,0));
  SELECT * INTO v_event FROM savings_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different command facts'; END IF;
    SELECT * INTO v_product FROM savings_products WHERE id=v_event.product_id; RETURN to_jsonb(v_product); END IF;
  SELECT * INTO v_product FROM savings_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
  IF v_product.id IS NULL THEN RAISE EXCEPTION 'Savings product not found'; END IF;
  IF v_product.state<>'draft' OR v_product.current_version<>p_expected_version THEN RAISE EXCEPTION 'Savings product is not an expected draft'; END IF;
  SELECT * INTO v_version FROM savings_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_expected_version FOR UPDATE;
  IF v_version.state<>'draft' THEN RAISE EXCEPTION 'Savings product version is not a draft'; END IF;
  PERFORM set_config('microfams.savings_engine','on',TRUE);
  UPDATE savings_product_versions SET state='pending_approval',submitted_at=p_at WHERE id=v_version.id;
  UPDATE savings_products SET state='pending_approval',updated_at=p_at WHERE id=v_product.id RETURNING * INTO v_product;
  INSERT INTO savings_product_events(organization_id,product_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,'submitted',p_actor,p_idempotency_key,v_hash,jsonb_build_object('version',p_expected_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'SAVINGS_PRODUCT_SUBMITTED','savings_product',p_product::TEXT,jsonb_build_object('version',p_expected_version),p_at);
  RETURN to_jsonb(v_product);
END $$;

CREATE OR REPLACE FUNCTION approve_savings_product(
  p_organization UUID,p_actor UUID,p_product UUID,p_expected_version INTEGER,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product savings_products; v_version savings_product_versions; v_event savings_product_events; v_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN RAISE EXCEPTION 'Missing financial.savings.configure permission'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,p_expected_version::TEXT,'approve'),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-product:'||p_product::TEXT,0));
  SELECT * INTO v_event FROM savings_product_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN IF v_event.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different command facts'; END IF;
    SELECT * INTO v_product FROM savings_products WHERE id=v_event.product_id; RETURN to_jsonb(v_product); END IF;
  SELECT * INTO v_product FROM savings_products WHERE id=p_product AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_version FROM savings_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=p_expected_version FOR UPDATE;
  IF v_product.id IS NULL OR v_version.id IS NULL THEN RAISE EXCEPTION 'Savings product not found'; END IF;
  IF v_product.state<>'pending_approval' OR v_version.state<>'pending_approval' THEN RAISE EXCEPTION 'Savings product is not pending approval'; END IF;
  IF v_version.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own savings product'; END IF;
  PERFORM set_config('microfams.savings_engine','on',TRUE);
  UPDATE savings_product_versions SET state='active',approved_by=p_actor,approved_at=p_at,effective_from=p_at WHERE id=v_version.id;
  UPDATE savings_products SET state='active',updated_at=p_at WHERE id=v_product.id RETURNING * INTO v_product;
  INSERT INTO savings_product_events(organization_id,product_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,'approved',p_actor,p_idempotency_key,v_hash,jsonb_build_object('version',p_expected_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'SAVINGS_PRODUCT_APPROVED','savings_product',p_product::TEXT,jsonb_build_object('version',p_expected_version),p_at);
  RETURN to_jsonb(v_product);
END $$;

CREATE OR REPLACE FUNCTION enrol_savings_product(
  p_organization UUID,p_actor UUID,p_product UUID,p_target_minor BIGINT,p_disclosure_version TEXT,p_disclosure_hash TEXT,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_product savings_products; v_version savings_product_versions; v_enrolment savings_enrolments; v_hash TEXT; v_principal UUID; v_returns UUID;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN
    RAISE EXCEPTION 'Actor is not an active organization member';
  END IF;
  SELECT * INTO v_product FROM savings_products WHERE id=p_product AND organization_id=p_organization AND state='active';
  IF v_product.id IS NULL THEN RAISE EXCEPTION 'Active savings product not found'; END IF;
  SELECT * INTO v_version FROM savings_product_versions WHERE product_id=p_product AND organization_id=p_organization AND version=v_product.current_version AND state='active';
  IF v_version.id IS NULL THEN RAISE EXCEPTION 'Active savings product version not found'; END IF;
  IF p_disclosure_version IS DISTINCT FROM v_version.disclosure_version OR lower(p_disclosure_hash) IS DISTINCT FROM v_version.disclosure_content_hash THEN
    RAISE EXCEPTION 'Accepted disclosure does not match the active product disclosure';
  END IF;
  IF p_target_minor IS NOT NULL AND p_target_minor < v_version.minimum_contribution_minor THEN RAISE EXCEPTION 'Savings target is below the product minimum'; END IF;
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product::TEXT,COALESCE(p_target_minor::TEXT,''),p_disclosure_version,lower(p_disclosure_hash)),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-enrolment:'||p_idempotency_key,0));
  SELECT * INTO v_enrolment FROM savings_enrolments WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_enrolment.id IS NOT NULL THEN IF v_enrolment.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different enrolment facts'; END IF; RETURN to_jsonb(v_enrolment); END IF;
  PERFORM set_config('microfams.savings_engine','on',TRUE);
  INSERT INTO savings_enrolments(organization_id,product_id,product_version_id,member_id,currency,target_minor,accepted_disclosure_version,
    accepted_disclosure_hash,accepted_at,lock_expires_at,idempotency_key,request_hash,created_at,updated_at)
    VALUES(p_organization,p_product,v_version.id,p_actor,v_product.currency,COALESCE(p_target_minor,v_version.default_target_minor),v_version.disclosure_version,
      v_version.disclosure_content_hash,p_at,p_at+make_interval(days=>v_version.lock_period_days),p_idempotency_key,v_hash,p_at,p_at)
    RETURNING * INTO v_enrolment;
  INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,status,created_by,
    purpose,effective_from,provisioning_key,provisioning_hash)
    VALUES(p_organization,'SAV.'||upper(substr(replace(v_enrolment.id::TEXT,'-',''),1,12))||'.PRI','Savings principal - '||v_product.name,
      'liability','credit',v_product.currency,'savings_contract',v_enrolment.id,TRUE,'active',p_actor,'savings_principal',p_at::DATE,
      'savings-principal:'||v_enrolment.id::TEXT,encode(digest(convert_to('savings-principal:'||v_enrolment.id::TEXT,'UTF8'),'sha256'),'hex')) RETURNING id INTO v_principal;
  INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,status,created_by,
    purpose,effective_from,provisioning_key,provisioning_hash)
    VALUES(p_organization,'SAV.'||upper(substr(replace(v_enrolment.id::TEXT,'-',''),1,12))||'.RET','Savings accrued return - '||v_product.name,
      'liability','credit',v_product.currency,'savings_contract',v_enrolment.id,TRUE,'active',p_actor,'savings_accrued_return',p_at::DATE,
      'savings-return:'||v_enrolment.id::TEXT,encode(digest(convert_to('savings-return:'||v_enrolment.id::TEXT,'UTF8'),'sha256'),'hex')) RETURNING id INTO v_returns;
  UPDATE savings_enrolments SET principal_account_id=v_principal,accrued_return_account_id=v_returns WHERE id=v_enrolment.id RETURNING * INTO v_enrolment;
  INSERT INTO savings_product_events(organization_id,product_id,enrolment_id,action,actor_id,idempotency_key,request_hash,evidence,occurred_at)
    VALUES(p_organization,p_product,v_enrolment.id,'enrolled',p_actor,p_idempotency_key,v_hash,
      jsonb_build_object('product_version',v_version.version,'disclosure_version',v_version.disclosure_version),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
    VALUES(p_organization,p_actor,'SAVINGS_PRODUCT_ENROLLED','savings_enrolment',v_enrolment.id::TEXT,
      jsonb_build_object('product_id',p_product,'product_version',v_version.version,'disclosure_version',v_version.disclosure_version),p_at);
  RETURN to_jsonb(v_enrolment);
END $$;

CREATE OR REPLACE FUNCTION list_active_savings_products(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('product',to_jsonb(p),'version',to_jsonb(v)) ORDER BY p.name)
    FROM savings_products p JOIN savings_product_versions v ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.version=p.current_version
    WHERE p.organization_id=p_organization AND p.state='active' AND v.state='active'),'[]'::JSONB);
END $$;

CREATE OR REPLACE FUNCTION list_member_savings_enrolments(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('enrolment',to_jsonb(e),'product',to_jsonb(p),'version',to_jsonb(v)) ORDER BY e.created_at DESC)
    FROM savings_enrolments e JOIN savings_products p ON p.organization_id=e.organization_id AND p.id=e.product_id
      JOIN savings_product_versions v ON v.organization_id=e.organization_id AND v.id=e.product_version_id
    WHERE e.organization_id=p_organization AND e.member_id=p_actor),'[]'::JSONB);
END $$;

UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT p FROM unnest(permissions||ARRAY['financial.savings.configure']) p)
  WHERE role='owner';

CREATE OR REPLACE FUNCTION provision_savings_owner_permission() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.role='owner' AND NOT ('financial.savings.configure'=ANY(NEW.permissions)) THEN
    NEW.permissions:=array_append(NEW.permissions,'financial.savings.configure');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS provision_savings_owner_permission_trigger ON organization_memberships;
CREATE TRIGGER provision_savings_owner_permission_trigger
  BEFORE INSERT OR UPDATE OF role,permissions ON organization_memberships
  FOR EACH ROW EXECUTE FUNCTION provision_savings_owner_permission();

ALTER TABLE savings_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_product_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_enrolments ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_product_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON savings_products,savings_product_versions,savings_enrolments,savings_product_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON savings_products,savings_product_versions,savings_enrolments,savings_product_events FROM service_role;
GRANT SELECT ON savings_products,savings_product_versions,savings_enrolments,savings_product_events TO service_role;
REVOKE ALL ON FUNCTION create_savings_product_draft(UUID,UUID,TEXT,TEXT,TEXT,BIGINT,BIGINT,TEXT,BIGINT,INTEGER,INTEGER,TEXT,BIGINT,TEXT,INTEGER,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_savings_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_savings_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION enrol_savings_product(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_active_savings_products(UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_member_savings_enrolments(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_savings_product_draft(UUID,UUID,TEXT,TEXT,TEXT,BIGINT,BIGINT,TEXT,BIGINT,INTEGER,INTEGER,TEXT,BIGINT,TEXT,INTEGER,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION submit_savings_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION approve_savings_product(UUID,UUID,UUID,INTEGER,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION enrol_savings_product(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_active_savings_products(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION list_member_savings_enrolments(UUID,UUID) TO service_role;
