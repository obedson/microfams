-- AC-05 immutable approved budget snapshots and journal-derived actuals.
SET search_path=public,extensions;
CREATE TABLE accounting_budget_versions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL REFERENCES organizations(id),period_id UUID NOT NULL REFERENCES accounting_periods(id),
 budget_key TEXT NOT NULL CHECK(budget_key~'^[a-z][a-z0-9_-]{1,47}$'),name TEXT NOT NULL CHECK(length(btrim(name)) BETWEEN 2 AND 160),currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
 version INTEGER NOT NULL CHECK(version>0),total_minor BIGINT NOT NULL CHECK(total_minor>=0),created_by UUID REFERENCES users(id) ON DELETE SET NULL,approved_at TIMESTAMPTZ NOT NULL,
 idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,budget_key,version),UNIQUE(organization_id,idempotency_key),UNIQUE(id,organization_id,currency)
);
CREATE TABLE accounting_budget_lines(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),budget_version_id UUID NOT NULL,organization_id UUID NOT NULL,currency VARCHAR(3) NOT NULL,account_id UUID NOT NULL,
 line_number INTEGER NOT NULL CHECK(line_number>0),amount_minor BIGINT NOT NULL CHECK(amount_minor>=0),memo TEXT CHECK(memo IS NULL OR length(memo)<=300),
 UNIQUE(budget_version_id,line_number),UNIQUE(budget_version_id,account_id),
 FOREIGN KEY(budget_version_id,organization_id,currency) REFERENCES accounting_budget_versions(id,organization_id,currency),
 FOREIGN KEY(account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency)
);
CREATE OR REPLACE FUNCTION protect_accounting_budget() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$ BEGIN RAISE EXCEPTION 'ACCOUNTING_BUDGET_IMMUTABLE'; END $$;
CREATE TRIGGER accounting_budget_versions_immutable BEFORE UPDATE OR DELETE ON accounting_budget_versions FOR EACH ROW EXECUTE FUNCTION protect_accounting_budget();
CREATE TRIGGER accounting_budget_lines_immutable BEFORE UPDATE OR DELETE ON accounting_budget_lines FOR EACH ROW EXECUTE FUNCTION protect_accounting_budget();
CREATE OR REPLACE FUNCTION create_accounting_budget_version(p_organization UUID,p_actor UUID,p_period UUID,p_budget_key TEXT,p_name TEXT,p_currency TEXT,p_lines JSONB,p_idempotency_key TEXT,p_approved_at TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; old accounting_budget_versions; budget_id UUID; next_version INTEGER; total BIGINT; cur TEXT:=upper(p_currency); h TEXT; item JSONB;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.post') THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_PERMISSION_DENIED'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE id=p_period AND organization_id=p_organization;
 IF period.id IS NULL OR period.status<>'open' OR p_budget_key IS NULL OR p_budget_key!~'^[a-z][a-z0-9_-]{1,47}$' OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 2 AND 160 OR cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_approved_at IS NULL OR p_approved_at>clock_timestamp() THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_REQUEST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) value WHERE NOT(value?'account_id' AND value?'amount_minor') OR (value->>'amount_minor')::BIGINT<0) THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_LINES_INVALID'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(p_lines))<>(SELECT count(DISTINCT value->>'account_id') FROM jsonb_array_elements(p_lines) value) THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_LINES_INVALID'; END IF;
 SELECT COALESCE(sum((value->>'amount_minor')::BIGINT),0)::BIGINT INTO total FROM jsonb_array_elements(p_lines) value;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_period,p_budget_key,btrim(p_name),cur,p_lines::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':accounting-budget:'||p_idempotency_key,0));
 SELECT * INTO old FROM accounting_budget_versions WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_IDEMPOTENCY_CONFLICT'; END IF; RETURN old.id; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) value LEFT JOIN financial_accounts account ON account.id=(value->>'account_id')::UUID AND account.organization_id=p_organization AND account.currency=cur WHERE account.id IS NULL) THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_ACCOUNT_INVALID'; END IF;
 SELECT COALESCE(max(version),0)+1 INTO next_version FROM accounting_budget_versions WHERE organization_id=p_organization AND budget_key=p_budget_key;
 INSERT INTO accounting_budget_versions(organization_id,period_id,budget_key,name,currency,version,total_minor,created_by,approved_at,idempotency_key,request_hash) VALUES(p_organization,p_period,p_budget_key,btrim(p_name),cur,next_version,total,p_actor,p_approved_at,p_idempotency_key,h) RETURNING id INTO budget_id;
 FOR item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP INSERT INTO accounting_budget_lines(budget_version_id,organization_id,currency,account_id,line_number,amount_minor,memo) VALUES(budget_id,p_organization,cur,(item->>'account_id')::UUID,COALESCE((item->>'line_number')::INTEGER,1),(item->>'amount_minor')::BIGINT,item->>'memo'); END LOOP;
 RETURN budget_id;
END $$;
CREATE OR REPLACE FUNCTION read_accounting_budget_vs_actual(p_organization UUID,p_actor UUID,p_currency TEXT,p_from DATE,p_to DATE,p_cutoff TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE period accounting_periods; budgets JSONB; cur TEXT:=upper(p_currency);
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.accounting.read') THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_READ_PERMISSION_DENIED'; END IF;
 IF cur IS NULL OR cur!~'^[A-Z]{3}$' OR p_from IS NULL OR p_to IS NULL OR p_from>p_to OR p_cutoff IS NULL OR p_cutoff>clock_timestamp() THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_READ_INVALID'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE organization_id=p_organization AND p_from>=starts_on AND p_to<=ends_on ORDER BY starts_on DESC LIMIT 1;
 IF period.id IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_BUDGET_PERIOD_REQUIRED'; END IF;
 WITH latest AS(SELECT DISTINCT ON(budget_key)* FROM accounting_budget_versions WHERE organization_id=p_organization AND period_id=period.id AND currency=cur AND approved_at<=p_cutoff AND created_at<=p_cutoff ORDER BY budget_key,version DESC), actuals AS(SELECT line.account_id,sum(CASE WHEN line.side='debit' THEN line.amount_minor ELSE -line.amount_minor END)::BIGINT actual FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id AND entry.organization_id=p_organization AND entry.currency=cur AND entry.status='posted' AND entry.effective_date BETWEEN p_from AND p_to AND entry.posted_at<=p_cutoff AND entry.created_at<=p_cutoff WHERE line.organization_id=p_organization AND line.currency=cur GROUP BY line.account_id), rendered AS(SELECT budget.id,budget.budget_key,budget.name,budget.version,budget.total_minor,jsonb_agg(jsonb_build_object('accountId',account.id,'code',account.code,'name',account.name,'budgetMinor',line.amount_minor::TEXT,'actualMinor',COALESCE(actual.actual,0)::TEXT,'varianceMinor',(line.amount_minor-COALESCE(actual.actual,0))::TEXT) ORDER BY line.line_number) lines FROM latest budget JOIN accounting_budget_lines line ON line.budget_version_id=budget.id JOIN financial_accounts account ON account.id=line.account_id LEFT JOIN actuals actual ON actual.account_id=line.account_id GROUP BY budget.id,budget.budget_key,budget.name,budget.version,budget.total_minor)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('budgetId',id,'budgetKey',budget_key,'name',name,'version',version,'totalMinor',total_minor::TEXT,'lines',lines) ORDER BY budget_key),'[]'::JSONB) INTO budgets FROM rendered;
 RETURN jsonb_build_object('organizationId',p_organization,'currency',cur,'from',p_from,'to',p_to,'cutoff',p_cutoff,'period',jsonb_build_object('id',period.id,'name',period.name,'startsOn',period.starts_on,'endsOn',period.ends_on),'budgets',budgets);
END $$;
REVOKE ALL ON accounting_budget_versions,accounting_budget_lines FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON accounting_budget_versions,accounting_budget_lines TO service_role;
REVOKE ALL ON FUNCTION create_accounting_budget_version(UUID,UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ),read_accounting_budget_vs_actual(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_accounting_budget_version(UUID,UUID,UUID,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ),read_accounting_budget_vs_actual(UUID,UUID,TEXT,DATE,DATE,TIMESTAMPTZ) TO service_role;
