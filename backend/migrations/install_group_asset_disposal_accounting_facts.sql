-- GT-10M approved-disposal accounting facts; execution remains disabled.
SET search_path=public,extensions;

-- Wallet cutover needs one wallet subledger per owner, while fixed assets need
-- distinct cost and contra-asset accounts for the same group and currency.
DROP INDEX IF EXISTS uq_financial_accounts_owned_subledger;
CREATE UNIQUE INDEX uq_financial_accounts_owned_subledger
 ON financial_accounts(organization_id,owner_type,owner_id,currency)
 WHERE owner_id IS NOT NULL AND owner_type IN('user','group')
   AND (purpose IS NULL OR purpose NOT IN('shared_asset_cost','accumulated_depreciation'));

CREATE TABLE IF NOT EXISTS group_asset_disposal_accounting_facts (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 disposal_request_id UUID NOT NULL UNIQUE REFERENCES group_shared_asset_disposal_requests(id),
 mapping_key TEXT NOT NULL, mapping_version INTEGER NOT NULL,
 currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
 original_cost_minor BIGINT NOT NULL CHECK(original_cost_minor>0),
 accumulated_depreciation_minor BIGINT NOT NULL CHECK(accumulated_depreciation_minor>=0),
 carrying_value_minor BIGINT NOT NULL CHECK(carrying_value_minor>=0),
 proceeds_minor BIGINT NOT NULL CHECK(proceeds_minor>=0),
 asset_cost_account_id UUID NOT NULL REFERENCES financial_accounts(id),
 accumulated_depreciation_account_id UUID NOT NULL REFERENCES financial_accounts(id),
 proceeds_account_id UUID REFERENCES financial_accounts(id),
 cost_ledger_evidence JSONB NOT NULL CHECK(jsonb_typeof(cost_ledger_evidence)='object' AND cost_ledger_evidence<>'{}'::JSONB),
 depreciation_ledger_evidence JSONB NOT NULL CHECK(jsonb_typeof(depreciation_ledger_evidence)='object' AND depreciation_ledger_evidence<>'{}'::JSONB),
 proceeds_evidence JSONB NOT NULL CHECK(jsonb_typeof(proceeds_evidence)='array'),
 effective_date DATE NOT NULL, accounting_period_id UUID NOT NULL REFERENCES accounting_periods(id),
 maker_id UUID NOT NULL REFERENCES users(id), checker_id UUID NOT NULL REFERENCES users(id),
 reconciliation_status TEXT NOT NULL DEFAULT 'pending' CHECK(reconciliation_status IN('pending','reconciled','exception')),
 recorded_by UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL,
 fact_hash VARCHAR(64) NOT NULL CHECK(fact_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
 recorded_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id),
 FOREIGN KEY(mapping_key,mapping_version) REFERENCES group_asset_journal_mappings(mapping_key,version),
 CHECK(accumulated_depreciation_minor<=original_cost_minor),
 CHECK(carrying_value_minor=original_cost_minor-accumulated_depreciation_minor),
 CHECK(maker_id<>checker_id),
 CHECK((mapping_key='disposal_with_proceeds' AND proceeds_minor>0 AND proceeds_account_id IS NOT NULL AND jsonb_array_length(proceeds_evidence)>0)
    OR (mapping_key='disposal_without_proceeds' AND proceeds_minor=0 AND proceeds_account_id IS NULL AND jsonb_array_length(proceeds_evidence)=0))
);
CREATE INDEX IF NOT EXISTS idx_group_asset_disposal_accounting_facts ON group_asset_disposal_accounting_facts(organization_id,group_id,asset_id,effective_date);

CREATE TABLE IF NOT EXISTS group_asset_disposal_accounting_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 disposal_request_id UUID NOT NULL REFERENCES group_shared_asset_disposal_requests(id),
 accounting_facts_id UUID NOT NULL REFERENCES group_asset_disposal_accounting_facts(id),
 actor_id UUID NOT NULL REFERENCES users(id), event_type TEXT NOT NULL CHECK(event_type='DISPOSAL_ACCOUNTING_FACTS_RECORDED'),
 correlation_id UUID NOT NULL, evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);

CREATE OR REPLACE FUNCTION protect_group_asset_disposal_accounting_evidence() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('microfams.group_asset_disposal_accounting_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_ENGINE_REQUIRED';
END $$;
DROP TRIGGER IF EXISTS protect_group_asset_disposal_accounting_evidence ON group_asset_disposal_accounting_facts;
CREATE TRIGGER protect_group_asset_disposal_accounting_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_asset_disposal_accounting_facts FOR EACH ROW EXECUTE FUNCTION protect_group_asset_disposal_accounting_evidence();
DROP TRIGGER IF EXISTS protect_group_asset_disposal_accounting_evidence ON group_asset_disposal_accounting_events;
CREATE TRIGGER protect_group_asset_disposal_accounting_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_asset_disposal_accounting_events FOR EACH ROW EXECUTE FUNCTION protect_group_asset_disposal_accounting_evidence();
ALTER TABLE group_asset_disposal_accounting_facts ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_asset_disposal_accounting_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_asset_disposal_accounting_facts FOR SELECT USING(has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON group_asset_disposal_accounting_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_asset_disposal_accounting_facts,group_asset_disposal_accounting_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_asset_disposal_accounting_facts,group_asset_disposal_accounting_events TO service_role;

CREATE OR REPLACE FUNCTION record_group_asset_disposal_accounting_facts(
 o UUID,g UUID,a UUID,request_id UUID,currency_code TEXT,original_cost BIGINT,accumulated_depreciation BIGINT,proceeds BIGINT,
 cost_account UUID,depreciation_account UUID,proceeds_account UUID,cost_evidence JSONB,depreciation_evidence JSONB,proceeds_refs JSONB,
 effective DATE,period_id UUID,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_disposal_requests; existing group_asset_disposal_accounting_facts; period accounting_periods;
 cost financial_accounts; depreciation financial_accounts; proceeds_target financial_accounts; mapping TEXT; h TEXT; fact_id UUID; cur TEXT:=upper(currency_code);
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) OR NOT has_financial_permission(o,a,'financial.accounts.manage') THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_PERMISSION_DENIED'; END IF;
 mapping:=CASE WHEN proceeds>0 THEN 'disposal_with_proceeds' ELSE 'disposal_without_proceeds' END;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,request_id,cur,original_cost,accumulated_depreciation,proceeds,cost_account,depreciation_account,COALESCE(proceeds_account::TEXT,''),cost_evidence::TEXT,depreciation_evidence::TEXT,proceeds_refs::TEXT,effective,period_id),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-disposal-accounting:'||idem,0));
 SELECT * INTO existing FROM group_asset_disposal_accounting_facts WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN IF existing.fact_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_IDEMPOTENCY_CONFLICT'; END IF; RETURN existing.id; END IF;
 IF cur IS NULL OR original_cost IS NULL OR accumulated_depreciation IS NULL OR proceeds IS NULL OR cost_account IS NULL OR depreciation_account IS NULL
  OR cur!~'^[A-Z]{3}$' OR original_cost<=0 OR accumulated_depreciation<0 OR accumulated_depreciation>original_cost OR proceeds<0
  OR jsonb_typeof(cost_evidence)<>'object' OR cost_evidence='{}'::JSONB OR jsonb_typeof(depreciation_evidence)<>'object' OR depreciation_evidence='{}'::JSONB
  OR jsonb_typeof(proceeds_refs)<>'array' OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160 OR effective IS NULL OR period_id IS NULL
 THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_FACTS_INVALID'; END IF;
 IF (proceeds>0 AND (proceeds_account IS NULL OR jsonb_array_length(proceeds_refs)=0)) OR (proceeds=0 AND (proceeds_account IS NOT NULL OR jsonb_array_length(proceeds_refs)<>0)) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_PROCEEDS_FACTS_INVALID'; END IF;
 SELECT * INTO r FROM group_shared_asset_disposal_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL OR r.state<>'approved' OR r.approved_by IS NULL OR r.created_by=r.approved_by THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_APPROVAL_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM group_asset_disposal_accounting_facts WHERE disposal_request_id=r.id) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_ALREADY_RECORDED'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE id=period_id AND organization_id=o;
 IF period.id IS NULL OR period.status<>'open' OR effective NOT BETWEEN period.starts_on AND period.ends_on THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ACCOUNTING_PERIOD_INVALID'; END IF;
 SELECT * INTO cost FROM financial_accounts WHERE id=cost_account AND organization_id=o AND currency=cur AND purpose='shared_asset_cost' AND owner_type='group' AND owner_id=g AND status='active';
 SELECT * INTO depreciation FROM financial_accounts WHERE id=depreciation_account AND organization_id=o AND currency=cur AND purpose='accumulated_depreciation' AND owner_type='group' AND owner_id=g AND status='active';
 IF cost.id IS NULL OR depreciation.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_LEDGER_ACCOUNTS_INVALID'; END IF;
 IF proceeds>0 THEN
  SELECT * INTO proceeds_target FROM financial_accounts WHERE id=proceeds_account AND organization_id=o AND currency=cur AND status='active'
   AND ((purpose='operating_cash' AND owner_type IN('organization','system') AND owner_id IS NULL)
     OR (purpose='asset_sale_receivable' AND ((owner_type='organization' AND owner_id IS NULL) OR (owner_type='group' AND owner_id=g))));
  IF proceeds_target.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_PROCEEDS_ACCOUNT_INVALID'; END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key=mapping AND version=1 AND execution_enabled=FALSE) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_MAPPING_UNAVAILABLE'; END IF;
 PERFORM set_config('microfams.group_asset_disposal_accounting_engine','on',TRUE);
 INSERT INTO group_asset_disposal_accounting_facts(organization_id,group_id,asset_id,disposal_request_id,mapping_key,mapping_version,currency,original_cost_minor,accumulated_depreciation_minor,carrying_value_minor,proceeds_minor,asset_cost_account_id,accumulated_depreciation_account_id,proceeds_account_id,cost_ledger_evidence,depreciation_ledger_evidence,proceeds_evidence,effective_date,accounting_period_id,maker_id,checker_id,recorded_by,idempotency_key,fact_hash,correlation_id,recorded_at)
 VALUES(o,g,r.asset_id,r.id,mapping,1,cur,original_cost,accumulated_depreciation,original_cost-accumulated_depreciation,proceeds,cost_account,depreciation_account,proceeds_account,cost_evidence,depreciation_evidence,proceeds_refs,effective,period_id,r.created_by,r.approved_by,a,idem,h,corr,at_time) RETURNING id INTO fact_id;
 INSERT INTO group_asset_disposal_accounting_events(organization_id,group_id,asset_id,disposal_request_id,accounting_facts_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,fact_id,a,'DISPOSAL_ACCOUNTING_FACTS_RECORDED',corr,jsonb_build_object('mapping_key',mapping,'mapping_version',1,'currency',cur,'original_cost_minor',original_cost,'accumulated_depreciation_minor',accumulated_depreciation,'carrying_value_minor',original_cost-accumulated_depreciation,'proceeds_minor',proceeds,'accounting_period_id',period_id,'reconciliation_status','pending','execution_enabled',false),at_time);
 PERFORM set_config('microfams.group_asset_disposal_accounting_engine','',TRUE); RETURN fact_id;
END $$;
REVOKE ALL ON FUNCTION record_group_asset_disposal_accounting_facts(UUID,UUID,UUID,UUID,TEXT,BIGINT,BIGINT,BIGINT,UUID,UUID,UUID,JSONB,JSONB,JSONB,DATE,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION record_group_asset_disposal_accounting_facts(UUID,UUID,UUID,UUID,TEXT,BIGINT,BIGINT,BIGINT,UUID,UUID,UUID,JSONB,JSONB,JSONB,DATE,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
REVOKE INSERT,UPDATE,DELETE ON group_asset_disposal_accounting_facts,group_asset_disposal_accounting_events FROM service_role;
