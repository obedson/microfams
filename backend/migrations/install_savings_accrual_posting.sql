-- SAV-03: deterministic savings-return accrual, independent approval, and
-- balanced posting to member accrued-return liabilities.

INSERT INTO financial_account_purpose_rules(purpose,account_class,normal_side,allowed_owner_types,is_control)
VALUES('savings_return_expense','expense','debit',ARRAY['organization','system'],FALSE)
ON CONFLICT (purpose) DO NOTHING;

CREATE TABLE savings_accrual_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  product_version_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending_approval' CHECK(state IN('pending_approval','posted','rejected')),
  return_method TEXT NOT NULL CHECK(return_method='simple_interest'),
  annual_rate_basis_points INTEGER NOT NULL CHECK(annual_rate_basis_points>0),
  day_count_convention TEXT NOT NULL CHECK(day_count_convention IN('actual_365','actual_360')),
  formula_version TEXT NOT NULL CHECK(formula_version='simple_interest_v1_half_up'),
  total_accrued_minor BIGINT NOT NULL DEFAULT 0 CHECK(total_accrued_minor>=0),
  item_count INTEGER NOT NULL DEFAULT 0 CHECK(item_count>=0),
  created_by UUID NOT NULL REFERENCES users(id),
  creation_idempotency_key TEXT NOT NULL CHECK(length(creation_idempotency_key) BETWEEN 8 AND 160),
  creation_request_hash VARCHAR(64) NOT NULL CHECK(creation_request_hash~'^[a-f0-9]{64}$'),
  creation_correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id),
  review_idempotency_key TEXT CHECK(review_idempotency_key IS NULL OR length(review_idempotency_key) BETWEEN 8 AND 160),
  review_request_hash VARCHAR(64) CHECK(review_request_hash IS NULL OR review_request_hash~'^[a-f0-9]{64}$'),
  review_correlation_id UUID,
  rejection_reason TEXT CHECK(rejection_reason IS NULL OR length(btrim(rejection_reason)) BETWEEN 8 AND 1000),
  reviewed_at TIMESTAMPTZ,
  journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  posted_at TIMESTAMPTZ,
  FOREIGN KEY(product_version_id,organization_id) REFERENCES savings_product_versions(id,organization_id),
  UNIQUE(organization_id,creation_idempotency_key),
  UNIQUE(organization_id,review_idempotency_key),
  UNIQUE(id,organization_id),
  CHECK(period_end>period_start),
  CHECK(
    (state='pending_approval' AND reviewed_by IS NULL AND review_idempotency_key IS NULL
      AND review_request_hash IS NULL AND review_correlation_id IS NULL AND rejection_reason IS NULL
      AND reviewed_at IS NULL AND journal_entry_id IS NULL AND posted_at IS NULL)
    OR (state='posted' AND reviewed_by IS NOT NULL AND reviewed_by<>created_by
      AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL
      AND review_correlation_id IS NOT NULL AND rejection_reason IS NULL
      AND reviewed_at IS NOT NULL AND journal_entry_id IS NOT NULL AND posted_at IS NOT NULL)
    OR (state='rejected' AND reviewed_by IS NOT NULL AND reviewed_by<>created_by
      AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL
      AND review_correlation_id IS NOT NULL AND rejection_reason IS NOT NULL
      AND reviewed_at IS NOT NULL AND journal_entry_id IS NULL AND posted_at IS NULL)
  )
);
CREATE INDEX idx_savings_accrual_batches_review
  ON savings_accrual_batches(organization_id,state,period_end,created_at);

CREATE TABLE savings_accrual_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  batch_id UUID NOT NULL,
  enrolment_id UUID NOT NULL,
  member_id UUID NOT NULL REFERENCES users(id),
  principal_account_id UUID NOT NULL,
  accrued_return_account_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  opening_principal_minor BIGINT NOT NULL CHECK(opening_principal_minor>=0),
  closing_principal_minor BIGINT NOT NULL CHECK(closing_principal_minor>=opening_principal_minor),
  eligible_principal_days_minor NUMERIC(38,0) NOT NULL CHECK(eligible_principal_days_minor>0),
  annual_rate_basis_points INTEGER NOT NULL CHECK(annual_rate_basis_points>0),
  day_count_convention TEXT NOT NULL CHECK(day_count_convention IN('actual_365','actual_360')),
  formula_version TEXT NOT NULL CHECK(formula_version='simple_interest_v1_half_up'),
  accrued_minor BIGINT NOT NULL CHECK(accrued_minor>0),
  calculation_hash VARCHAR(64) NOT NULL CHECK(calculation_hash~'^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(batch_id,organization_id) REFERENCES savings_accrual_batches(id,organization_id),
  FOREIGN KEY(enrolment_id,organization_id) REFERENCES savings_enrolments(id,organization_id),
  FOREIGN KEY(principal_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY(accrued_return_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  UNIQUE(batch_id,enrolment_id),
  UNIQUE(id,organization_id)
);
CREATE INDEX idx_savings_accrual_items_member
  ON savings_accrual_items(organization_id,member_id,enrolment_id,created_at DESC);

CREATE TABLE savings_accrual_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  batch_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('calculated','approved','rejected')),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK(jsonb_typeof(evidence)='object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(batch_id,organization_id) REFERENCES savings_accrual_batches(id,organization_id),
  UNIQUE(organization_id,idempotency_key)
);

CREATE OR REPLACE FUNCTION require_savings_accrual_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF current_setting('microfams.savings_accrual_engine',TRUE) IS DISTINCT FROM 'on' THEN
   RAISE EXCEPTION 'SAVINGS_ACCRUAL_ENGINE_REQUIRED';
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER savings_accrual_batches_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_accrual_batches
  FOR EACH ROW EXECUTE FUNCTION require_savings_accrual_engine();
CREATE TRIGGER savings_accrual_items_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_accrual_items
  FOR EACH ROW EXECUTE FUNCTION require_savings_accrual_engine();
CREATE TRIGGER savings_accrual_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_accrual_events
  FOR EACH ROW EXECUTE FUNCTION require_savings_accrual_engine();

CREATE OR REPLACE FUNCTION calculate_savings_accrual_batch(
 p_organization UUID,p_actor UUID,p_product_version UUID,p_period_start DATE,p_period_end DATE,
 p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v savings_product_versions; product savings_products; old savings_accrual_batches; batch savings_accrual_batches;
 h TEXT; count_items INTEGER; total_minor BIGINT; denominator NUMERIC;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end<=p_period_start THEN RAISE EXCEPTION 'Accrual period is invalid'; END IF;
 IF p_period_end>p_at::DATE THEN RAISE EXCEPTION 'Accrual period must contain completed days only'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Accrual command identity is invalid';
 END IF;
 SELECT * INTO v FROM savings_product_versions
 WHERE id=p_product_version AND organization_id=p_organization AND state IN('active','retired');
 IF v.id IS NULL THEN RAISE EXCEPTION 'Savings product version is unavailable for accrual'; END IF;
 IF v.return_method<>'simple_interest' OR v.annual_rate_basis_points<=0 THEN RAISE EXCEPTION 'Savings product has no accruing return'; END IF;
 SELECT * INTO product FROM savings_products WHERE id=v.product_id AND organization_id=p_organization;
 IF product.id IS NULL OR product.currency IS NULL THEN RAISE EXCEPTION 'Savings product is unavailable'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_product_version::TEXT,
   p_period_start::TEXT,p_period_end::TEXT,p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-accrual',0));
 SELECT * INTO old FROM savings_accrual_batches WHERE organization_id=p_organization AND creation_idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN
   IF old.creation_request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different accrual facts'; END IF;
   RETURN jsonb_build_object('batch',to_jsonb(old),'items',
     COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.enrolment_id) FROM savings_accrual_items i WHERE i.batch_id=old.id),'[]'::JSONB));
 END IF;
 IF EXISTS(
   SELECT 1 FROM savings_accrual_batches b
   WHERE b.organization_id=p_organization AND b.product_version_id=p_product_version
     AND b.state<>'rejected' AND daterange(b.period_start,b.period_end,'[)') && daterange(p_period_start,p_period_end,'[)')
 ) THEN RAISE EXCEPTION 'Accrual period overlaps an existing active calculation'; END IF;

 PERFORM set_config('microfams.savings_accrual_engine','on',TRUE);
 INSERT INTO savings_accrual_batches(organization_id,product_version_id,currency,period_start,period_end,return_method,
   annual_rate_basis_points,day_count_convention,formula_version,created_by,creation_idempotency_key,
   creation_request_hash,creation_correlation_id,created_at)
 VALUES(p_organization,p_product_version,product.currency,p_period_start,p_period_end,v.return_method,v.annual_rate_basis_points,
   v.day_count_convention,'simple_interest_v1_half_up',p_actor,p_idempotency_key,h,p_correlation_id,p_at)
 RETURNING * INTO batch;
 denominator:=10000::NUMERIC*CASE v.day_count_convention WHEN 'actual_365' THEN 365 ELSE 360 END;

 WITH metrics AS (
   SELECT e.id enrolment_id,e.member_id,e.principal_account_id,e.accrued_return_account_id,e.currency,
     COALESCE(sum(c.amount_minor) FILTER(WHERE c.contributed_at::DATE<p_period_start),0)::BIGINT opening_minor,
     sum(c.amount_minor)::BIGINT closing_minor,
     sum(c.amount_minor::NUMERIC*(p_period_end-GREATEST(c.contributed_at::DATE,p_period_start))) eligible_days
   FROM savings_enrolments e
   JOIN savings_contributions c ON c.organization_id=e.organization_id AND c.enrolment_id=e.id
     AND c.contributed_at::DATE<p_period_end
   WHERE e.organization_id=p_organization AND e.product_version_id=p_product_version AND e.state IN('active','locked')
     AND e.principal_account_id IS NOT NULL AND e.accrued_return_account_id IS NOT NULL
   GROUP BY e.id,e.member_id,e.principal_account_id,e.accrued_return_account_id,e.currency
 ), calculated AS (
   SELECT metrics.*,floor((eligible_days*v.annual_rate_basis_points+denominator/2)/denominator)::BIGINT accrued_minor
   FROM metrics WHERE eligible_days>0
 )
 INSERT INTO savings_accrual_items(organization_id,batch_id,enrolment_id,member_id,principal_account_id,
   accrued_return_account_id,currency,opening_principal_minor,closing_principal_minor,eligible_principal_days_minor,
   annual_rate_basis_points,day_count_convention,formula_version,accrued_minor,calculation_hash,created_at)
 SELECT p_organization,batch.id,enrolment_id,member_id,principal_account_id,accrued_return_account_id,currency,
   opening_minor,closing_minor,eligible_days,v.annual_rate_basis_points,v.day_count_convention,'simple_interest_v1_half_up',
   accrued_minor,encode(digest(convert_to(concat_ws('|',batch.id::TEXT,enrolment_id::TEXT,opening_minor::TEXT,
     closing_minor::TEXT,eligible_days::TEXT,v.annual_rate_basis_points::TEXT,v.day_count_convention,accrued_minor::TEXT),'UTF8'),'sha256'),'hex'),p_at
 FROM calculated WHERE accrued_minor>0;

 SELECT count(*),COALESCE(sum(accrued_minor),0)::BIGINT INTO count_items,total_minor
 FROM savings_accrual_items WHERE batch_id=batch.id;
 IF count_items=0 OR total_minor<=0 THEN RAISE EXCEPTION 'Accrual period produced no positive member returns'; END IF;
 UPDATE savings_accrual_batches SET item_count=count_items,total_accrued_minor=total_minor WHERE id=batch.id RETURNING * INTO batch;
 INSERT INTO savings_accrual_events(organization_id,batch_id,action,actor_id,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,batch.id,'calculated',p_actor,p_idempotency_key,h,p_correlation_id,
   jsonb_build_object('product_version_id',p_product_version,'period_start',p_period_start,'period_end',p_period_end,
     'item_count',count_items,'total_accrued_minor',total_minor,'formula_version',batch.formula_version),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_ACCRUAL_CALCULATED','savings_accrual_batch',batch.id::TEXT,
   jsonb_build_object('product_version_id',p_product_version,'period_start',p_period_start,'period_end',p_period_end,
     'item_count',count_items,'total_accrued_minor',total_minor,'currency',product.currency),p_at);
 RETURN jsonb_build_object('batch',to_jsonb(batch),'items',
   COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.enrolment_id) FROM savings_accrual_items i WHERE i.batch_id=batch.id),'[]'::JSONB));
END $$;

CREATE OR REPLACE FUNCTION approve_savings_accrual_batch(
 p_organization UUID,p_actor UUID,p_batch UUID,p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 batch savings_accrual_batches; event savings_accrual_events; expense financial_accounts;
 h TEXT; lines JSONB; journal UUID; account_hash TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Accrual review identity is invalid';
 END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_batch::TEXT,'approve',p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-accrual',0));
 SELECT * INTO event FROM savings_accrual_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF event.id IS NOT NULL THEN
   IF event.request_hash<>h OR event.batch_id<>p_batch OR event.action<>'approved' THEN RAISE EXCEPTION 'Idempotency key reused with different accrual review facts'; END IF;
   SELECT * INTO batch FROM savings_accrual_batches WHERE id=p_batch AND organization_id=p_organization;
   RETURN to_jsonb(batch);
 END IF;
 SELECT * INTO batch FROM savings_accrual_batches WHERE id=p_batch AND organization_id=p_organization FOR UPDATE;
 IF batch.id IS NULL OR batch.state<>'pending_approval' THEN RAISE EXCEPTION 'Accrual batch is not pending approval'; END IF;
 IF batch.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own savings accrual'; END IF;

 SELECT * INTO expense FROM financial_accounts WHERE organization_id=p_organization AND purpose='savings_return_expense'
   AND owner_type='organization' AND owner_id IS NULL AND currency=batch.currency AND effective_until IS NULL FOR UPDATE;
 IF expense.id IS NULL THEN
   account_hash:=encode(digest(convert_to('savings-return-expense:'||p_organization::TEXT||':'||batch.currency,'UTF8'),'sha256'),'hex');
   INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,status,
     created_by,purpose,effective_from,provisioning_key,provisioning_hash)
   VALUES(p_organization,'SAV.RET.EXP.'||batch.currency,'Savings return expense - '||batch.currency,'expense','debit',batch.currency,
     'organization',NULL,FALSE,'active',p_actor,'savings_return_expense',batch.period_end-1,
     'savings-return-expense:'||batch.currency,account_hash) RETURNING * INTO expense;
 END IF;
 SELECT jsonb_agg(line ORDER BY line_number) INTO lines FROM (
   SELECT 1 line_number,jsonb_build_object('account_id',expense.id,'line_number',1,'side','debit',
     'amount_minor',batch.total_accrued_minor,'memo','Approved savings return expense') line
   UNION ALL
   SELECT row_number() OVER(ORDER BY i.enrolment_id)::INTEGER+1,
     jsonb_build_object('account_id',i.accrued_return_account_id,
       'line_number',row_number() OVER(ORDER BY i.enrolment_id)::INTEGER+1,'side','credit',
       'amount_minor',i.accrued_minor,'memo','Approved member savings return')
   FROM savings_accrual_items i WHERE i.batch_id=batch.id
 ) journal_lines;
 journal:=post_financial_journal(p_organization,batch.currency,batch.period_end-1,'savings.accrual',batch.id::TEXT,
   p_idempotency_key,h,p_correlation_id,'Approved savings return accrual',p_actor,lines);
 PERFORM set_config('microfams.savings_accrual_engine','on',TRUE);
 UPDATE savings_accrual_batches SET state='posted',reviewed_by=p_actor,review_idempotency_key=p_idempotency_key,
   review_request_hash=h,review_correlation_id=p_correlation_id,reviewed_at=p_at,journal_entry_id=journal,posted_at=p_at
 WHERE id=batch.id RETURNING * INTO batch;
 INSERT INTO savings_accrual_events(organization_id,batch_id,action,actor_id,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,batch.id,'approved',p_actor,p_idempotency_key,h,p_correlation_id,
   jsonb_build_object('journal_entry_id',journal,'item_count',batch.item_count,'total_accrued_minor',batch.total_accrued_minor),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_ACCRUAL_POSTED','savings_accrual_batch',batch.id::TEXT,
   jsonb_build_object('journal_entry_id',journal,'item_count',batch.item_count,'total_accrued_minor',batch.total_accrued_minor,
     'currency',batch.currency),p_at);
 RETURN to_jsonb(batch);
END $$;

CREATE OR REPLACE FUNCTION reject_savings_accrual_batch(
 p_organization UUID,p_actor UUID,p_batch UUID,p_reason TEXT,p_idempotency_key TEXT,p_correlation_id UUID,
 p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE batch savings_accrual_batches; event savings_accrual_events; h TEXT; reason TEXT:=btrim(p_reason);
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 IF reason IS NULL OR length(reason) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Accrual rejection reason is invalid'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Accrual review identity is invalid';
 END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_batch::TEXT,'reject',reason,p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-accrual',0));
 SELECT * INTO event FROM savings_accrual_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF event.id IS NOT NULL THEN
   IF event.request_hash<>h OR event.batch_id<>p_batch OR event.action<>'rejected' THEN RAISE EXCEPTION 'Idempotency key reused with different accrual review facts'; END IF;
   SELECT * INTO batch FROM savings_accrual_batches WHERE id=p_batch AND organization_id=p_organization; RETURN to_jsonb(batch);
 END IF;
 SELECT * INTO batch FROM savings_accrual_batches WHERE id=p_batch AND organization_id=p_organization FOR UPDATE;
 IF batch.id IS NULL OR batch.state<>'pending_approval' THEN RAISE EXCEPTION 'Accrual batch is not pending approval'; END IF;
 IF batch.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot review their own savings accrual'; END IF;
 PERFORM set_config('microfams.savings_accrual_engine','on',TRUE);
 UPDATE savings_accrual_batches SET state='rejected',reviewed_by=p_actor,review_idempotency_key=p_idempotency_key,
   review_request_hash=h,review_correlation_id=p_correlation_id,rejection_reason=reason,reviewed_at=p_at
 WHERE id=batch.id RETURNING * INTO batch;
 INSERT INTO savings_accrual_events(organization_id,batch_id,action,actor_id,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,batch.id,'rejected',p_actor,p_idempotency_key,h,p_correlation_id,
   jsonb_build_object('reason',reason,'item_count',batch.item_count,'total_accrued_minor',batch.total_accrued_minor),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_ACCRUAL_REJECTED','savings_accrual_batch',batch.id::TEXT,
   jsonb_build_object('reason',reason,'item_count',batch.item_count,'total_accrued_minor',batch.total_accrued_minor),p_at);
 RETURN to_jsonb(batch);
END $$;

CREATE OR REPLACE FUNCTION list_savings_accrual_batches(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public AS $$
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.created_at DESC) FROM savings_accrual_batches b
   WHERE b.organization_id=p_organization),'[]'::JSONB);
END $$;

CREATE OR REPLACE FUNCTION list_member_savings_accruals(p_organization UUID,p_actor UUID,p_enrolment UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor) THEN
   RAISE EXCEPTION 'Savings enrolment not found';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(i)||jsonb_build_object('state',b.state,'period_start',b.period_start,
     'period_end',b.period_end,'reviewed_at',b.reviewed_at,'posted_at',b.posted_at) ORDER BY b.period_end DESC)
   FROM savings_accrual_items i JOIN savings_accrual_batches b ON b.id=i.batch_id AND b.organization_id=i.organization_id
   WHERE i.organization_id=p_organization AND i.enrolment_id=p_enrolment),'[]'::JSONB);
END $$;

ALTER TABLE savings_accrual_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_accrual_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_accrual_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON savings_accrual_batches,savings_accrual_items,savings_accrual_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON savings_accrual_batches,savings_accrual_items,savings_accrual_events FROM service_role;
GRANT SELECT ON savings_accrual_batches,savings_accrual_items,savings_accrual_events TO service_role;
REVOKE ALL ON FUNCTION calculate_savings_accrual_batch(UUID,UUID,UUID,DATE,DATE,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_savings_accrual_batch(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION reject_savings_accrual_batch(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_savings_accrual_batches(UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_member_savings_accruals(UUID,UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_savings_accrual_batch(UUID,UUID,UUID,DATE,DATE,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION approve_savings_accrual_batch(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION reject_savings_accrual_batch(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_savings_accrual_batches(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION list_member_savings_accruals(UUID,UUID,UUID) TO service_role;
