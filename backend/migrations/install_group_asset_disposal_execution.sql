-- GT-10N atomic shared-asset disposal execution and journal posting.
SET search_path=public,extensions;

-- Disposal accounting needs distinct cost, contra-asset, receivable, gain, and
-- loss subledgers for the same group and currency.
DROP INDEX IF EXISTS uq_financial_accounts_owned_subledger;
CREATE UNIQUE INDEX uq_financial_accounts_owned_subledger
 ON financial_accounts(organization_id,owner_type,owner_id,currency)
 WHERE owner_id IS NOT NULL AND owner_type IN('user','group')
   AND (purpose IS NULL OR purpose NOT IN(
     'shared_asset_cost','accumulated_depreciation','asset_sale_receivable',
     'asset_disposal_gain','asset_disposal_loss'
   ));

ALTER TABLE group_asset_journal_mappings DROP CONSTRAINT IF EXISTS group_asset_journal_execution_disabled;
ALTER TABLE group_asset_journal_mappings DROP CONSTRAINT IF EXISTS group_asset_transfer_execution_disabled;
ALTER TABLE group_asset_journal_mappings ADD CONSTRAINT group_asset_transfer_execution_disabled
 CHECK(mapping_key<>'book_value_transfer' OR execution_enabled=FALSE);
UPDATE group_asset_journal_mappings SET execution_enabled=TRUE
 WHERE mapping_key IN('disposal_with_proceeds','disposal_without_proceeds') AND version=1;

-- Facts may continue to be recorded after the approved disposal mappings become executable.
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
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key=mapping AND version=1 AND execution_enabled=TRUE) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_MAPPING_UNAVAILABLE'; END IF;
 PERFORM set_config('microfams.group_asset_disposal_accounting_engine','on',TRUE);
 INSERT INTO group_asset_disposal_accounting_facts(organization_id,group_id,asset_id,disposal_request_id,mapping_key,mapping_version,currency,original_cost_minor,accumulated_depreciation_minor,carrying_value_minor,proceeds_minor,asset_cost_account_id,accumulated_depreciation_account_id,proceeds_account_id,cost_ledger_evidence,depreciation_ledger_evidence,proceeds_evidence,effective_date,accounting_period_id,maker_id,checker_id,recorded_by,idempotency_key,fact_hash,correlation_id,recorded_at)
 VALUES(o,g,r.asset_id,r.id,mapping,1,cur,original_cost,accumulated_depreciation,original_cost-accumulated_depreciation,proceeds,cost_account,depreciation_account,proceeds_account,cost_evidence,depreciation_evidence,proceeds_refs,effective,period_id,r.created_by,r.approved_by,a,idem,h,corr,at_time) RETURNING id INTO fact_id;
 INSERT INTO group_asset_disposal_accounting_events(organization_id,group_id,asset_id,disposal_request_id,accounting_facts_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,fact_id,a,'DISPOSAL_ACCOUNTING_FACTS_RECORDED',corr,jsonb_build_object('mapping_key',mapping,'mapping_version',1,'currency',cur,'original_cost_minor',original_cost,'accumulated_depreciation_minor',accumulated_depreciation,'carrying_value_minor',original_cost-accumulated_depreciation,'proceeds_minor',proceeds,'accounting_period_id',period_id,'reconciliation_status','pending','execution_enabled',false),at_time);
 PERFORM set_config('microfams.group_asset_disposal_accounting_engine','',TRUE); RETURN fact_id;
END $$;

ALTER TABLE group_shared_asset_disposal_requests ADD COLUMN executed_by UUID REFERENCES users(id), ADD COLUMN executed_at TIMESTAMPTZ, ADD COLUMN execution_journal_entry_id UUID REFERENCES journal_entries(id);
ALTER TABLE group_shared_asset_disposal_requests DROP CONSTRAINT IF EXISTS group_shared_asset_disposal_requests_state_check;
ALTER TABLE group_shared_asset_disposal_requests DROP CONSTRAINT IF EXISTS group_shared_asset_disposal_requests_check;
ALTER TABLE group_shared_asset_disposal_requests ADD CONSTRAINT group_shared_asset_disposal_requests_state_check CHECK(state IN('draft','proposed','approved','executed','cancelled'));
ALTER TABLE group_shared_asset_disposal_requests ADD CONSTRAINT group_shared_asset_disposal_approval_consistency CHECK((state IN('approved','executed'))=(approved_by IS NOT NULL AND approved_at IS NOT NULL));
ALTER TABLE group_shared_asset_disposal_requests ADD CONSTRAINT group_shared_asset_disposal_execution_consistency CHECK((state='executed')=(executed_by IS NOT NULL AND executed_at IS NOT NULL AND execution_journal_entry_id IS NOT NULL));
ALTER TABLE group_shared_asset_disposal_events DROP CONSTRAINT IF EXISTS group_shared_asset_disposal_events_event_type_check;
ALTER TABLE group_shared_asset_disposal_events ADD CONSTRAINT group_shared_asset_disposal_events_event_type_check CHECK(event_type IN('DISPOSAL_REQUESTED','DISPOSAL_SUBMITTED','DISPOSAL_APPROVED','DISPOSAL_EXECUTED'));
ALTER TABLE group_shared_asset_events DROP CONSTRAINT IF EXISTS group_shared_asset_events_event_type_check;
ALTER TABLE group_shared_asset_events ADD CONSTRAINT group_shared_asset_events_event_type_check CHECK(event_type IN('ASSET_REGISTERED','ASSET_DISPOSED'));

CREATE TABLE IF NOT EXISTS group_asset_disposal_executions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id), group_id UUID NOT NULL REFERENCES groups(id),
 asset_id UUID NOT NULL REFERENCES group_shared_assets(id), disposal_request_id UUID NOT NULL UNIQUE REFERENCES group_shared_asset_disposal_requests(id),
 accounting_facts_id UUID NOT NULL UNIQUE REFERENCES group_asset_disposal_accounting_facts(id), journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
 balancing_account_id UUID REFERENCES financial_accounts(id), disposal_gain_minor BIGINT NOT NULL CHECK(disposal_gain_minor>=0), disposal_loss_minor BIGINT NOT NULL CHECK(disposal_loss_minor>=0),
 reconciliation_status TEXT NOT NULL DEFAULT 'pending' CHECK(reconciliation_status IN('pending','reconciled','exception')),
 executed_by UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL, execution_hash VARCHAR(64) NOT NULL CHECK(execution_hash~'^[a-f0-9]{64}$'),
 correlation_id UUID NOT NULL, executed_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id),
 CHECK(NOT(disposal_gain_minor>0 AND disposal_loss_minor>0)), CHECK((disposal_gain_minor>0 OR disposal_loss_minor>0)=(balancing_account_id IS NOT NULL))
);
ALTER TABLE group_asset_disposal_executions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_asset_disposal_executions FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_asset_disposal_executions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_asset_disposal_executions TO service_role;

CREATE OR REPLACE FUNCTION protect_group_asset_disposal_execution() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('microfams.group_asset_disposal_execution_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_ENGINE_REQUIRED';
END $$;
CREATE TRIGGER protect_group_asset_disposal_execution BEFORE INSERT OR UPDATE OR DELETE ON group_asset_disposal_executions FOR EACH ROW EXECUTE FUNCTION protect_group_asset_disposal_execution();

CREATE OR REPLACE FUNCTION execute_group_shared_asset_disposal(o UUID,g UUID,a UUID,request_id UUID,balancing_account UUID,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_disposal_requests; asset group_shared_assets; f group_asset_disposal_accounting_facts; existing group_asset_disposal_executions;
 balance financial_accounts; cost_balance BIGINT; depreciation_balance BIGINT; gain BIGINT; loss BIGINT;
 lines JSONB:='[]'::JSONB; n INTEGER:=0; h TEXT; journal UUID; execution_id UUID;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) OR NOT has_financial_permission(o,a,'financial.accounts.manage') THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_PERMISSION_DENIED'; END IF;
 SELECT * INTO r FROM group_shared_asset_disposal_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO f FROM group_asset_disposal_accounting_facts WHERE disposal_request_id=request_id AND organization_id=o FOR UPDATE;
 IF r.id IS NULL OR f.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_FACTS_REQUIRED'; END IF;
 gain:=GREATEST(f.proceeds_minor-f.carrying_value_minor,0); loss:=GREATEST(f.carrying_value_minor-f.proceeds_minor,0);
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,r.id,f.id,f.fact_hash,COALESCE(balancing_account::TEXT,''),gain,loss,idem),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-disposal-execution:'||idem,0));
 SELECT * INTO existing FROM group_asset_disposal_executions WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN IF existing.execution_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_IDEMPOTENCY_CONFLICT'; END IF; RETURN existing.id; END IF;
 IF r.state<>'approved' OR f.reconciliation_status<>'pending' OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_STATE_INVALID'; END IF;
 SELECT * INTO asset FROM group_shared_assets WHERE id=r.asset_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF asset.id IS NULL OR asset.lifecycle_state<>'active' OR asset.availability_state NOT IN('available','unavailable') OR EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=asset.id AND x.state IN('requested','confirmed','checked_out')) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_ASSET_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE id=f.accounting_period_id AND organization_id=o AND status='open' AND f.effective_date BETWEEN starts_on AND ends_on) OR NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key=f.mapping_key AND version=f.mapping_version AND execution_enabled=TRUE) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_EXECUTION_ACCOUNTING_INVALID'; END IF;
 SELECT COALESCE(sum(CASE WHEN line.side='debit' THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT INTO cost_balance
 FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
 WHERE line.organization_id=o AND line.account_id=f.asset_cost_account_id AND entry.status='posted';
 SELECT COALESCE(sum(CASE WHEN line.side='credit' THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT INTO depreciation_balance
 FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id
 WHERE line.organization_id=o AND line.account_id=f.accumulated_depreciation_account_id AND entry.status='posted';
 IF cost_balance<>f.original_cost_minor OR depreciation_balance<>f.accumulated_depreciation_minor THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_LEDGER_BALANCES_INVALID'; END IF;
 IF gain>0 OR loss>0 THEN
  SELECT * INTO balance FROM financial_accounts WHERE id=balancing_account AND organization_id=o AND currency=f.currency AND status='active'
   AND ((gain>0 AND purpose='asset_disposal_gain') OR (loss>0 AND purpose='asset_disposal_loss'))
   AND ((owner_type='organization' AND owner_id IS NULL) OR (owner_type='group' AND owner_id=g));
  IF balance.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_BALANCING_ACCOUNT_INVALID'; END IF;
 ELSIF balancing_account IS NOT NULL THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_BALANCING_ACCOUNT_UNNEEDED'; END IF;
 IF f.proceeds_minor>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.proceeds_account_id,'line_number',n,'side','debit','amount_minor',f.proceeds_minor)); END IF;
 IF f.accumulated_depreciation_minor>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.accumulated_depreciation_account_id,'line_number',n,'side','debit','amount_minor',f.accumulated_depreciation_minor)); END IF;
 IF loss>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',balance.id,'line_number',n,'side','debit','amount_minor',loss)); END IF;
 n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.asset_cost_account_id,'line_number',n,'side','credit','amount_minor',f.original_cost_minor));
 IF gain>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',balance.id,'line_number',n,'side','credit','amount_minor',gain)); END IF;
 journal:=post_financial_journal(o,f.currency,f.effective_date,'groups.asset_disposal',r.id::TEXT,idem,h,corr,'Dispose shared asset '||asset.name,a,lines);
 PERFORM set_config('microfams.group_asset_disposal_execution_engine','on',TRUE);
 INSERT INTO group_asset_disposal_executions(organization_id,group_id,asset_id,disposal_request_id,accounting_facts_id,journal_entry_id,balancing_account_id,disposal_gain_minor,disposal_loss_minor,executed_by,idempotency_key,execution_hash,correlation_id,executed_at)
 VALUES(o,g,asset.id,r.id,f.id,journal,balancing_account,gain,loss,a,idem,h,corr,at_time) RETURNING id INTO execution_id;
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','on',TRUE); PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_disposal_requests SET state='executed',executed_by=a,executed_at=at_time,execution_journal_entry_id=journal,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET lifecycle_state='disposed',availability_state='unavailable',updated_at=at_time WHERE id=asset.id;
 INSERT INTO group_shared_asset_disposal_events(organization_id,group_id,asset_id,disposal_request_id,actor_id,event_type,proposal_id,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset.id,r.id,a,'DISPOSAL_EXECUTED',r.proposal_id,corr,jsonb_build_object('accounting_facts_id',f.id,'journal_entry_id',journal,'mapping_key',f.mapping_key,'disposal_gain_minor',gain,'disposal_loss_minor',loss,'reconciliation_status','pending'),at_time);
 INSERT INTO group_shared_asset_events(organization_id,group_id,asset_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset.id,a,'ASSET_DISPOSED',gen_random_uuid(),jsonb_build_object('disposal_request_id',r.id,'execution_id',execution_id,'journal_entry_id',journal),at_time);
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','',TRUE); PERFORM set_config('microfams.group_shared_asset_engine','',TRUE); PERFORM set_config('microfams.group_asset_disposal_execution_engine','',TRUE);
 RETURN execution_id;
END $$;
REVOKE ALL ON FUNCTION execute_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION execute_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
REVOKE INSERT,UPDATE,DELETE ON group_asset_disposal_executions FROM service_role;
