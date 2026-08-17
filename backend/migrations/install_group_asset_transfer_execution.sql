-- GT-10P atomic book-value group asset transfer execution and journal posting.
SET search_path=public,extensions;

ALTER TABLE group_asset_journal_mappings DROP CONSTRAINT IF EXISTS group_asset_transfer_execution_disabled;
UPDATE group_asset_journal_mappings SET execution_enabled=TRUE
 WHERE mapping_key='book_value_transfer' AND version=1;

-- Facts may continue to be recorded after the approved transfer mapping becomes executable.
CREATE OR REPLACE FUNCTION record_group_asset_transfer_accounting_facts(
 o UUID,g UUID,a UUID,request_id UUID,destination_group UUID,currency_code TEXT,original_cost BIGINT,accumulated_depreciation BIGINT,
 source_cost_account UUID,source_depreciation_account UUID,destination_cost_account UUID,destination_depreciation_account UUID,
 cost_evidence JSONB,depreciation_evidence JSONB,acceptance_evidence JSONB,effective DATE,period_id UUID,idem TEXT,corr UUID,
 at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_transfer_requests; existing group_asset_transfer_accounting_facts; period accounting_periods;
 source_cost financial_accounts; source_depreciation financial_accounts; destination_cost financial_accounts; destination_depreciation financial_accounts;
 h TEXT; fact_id UUID; cur TEXT:=upper(currency_code);
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) OR NOT has_financial_permission(o,a,'financial.accounts.manage') THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_PERMISSION_DENIED'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,request_id,destination_group,cur,original_cost,accumulated_depreciation,source_cost_account,source_depreciation_account,destination_cost_account,destination_depreciation_account,cost_evidence::TEXT,depreciation_evidence::TEXT,acceptance_evidence::TEXT,effective,period_id),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-transfer-accounting:'||idem,0));
 SELECT * INTO existing FROM group_asset_transfer_accounting_facts WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN IF existing.fact_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_IDEMPOTENCY_CONFLICT'; END IF; RETURN existing.id; END IF;
 IF destination_group IS NULL OR destination_group=g OR cur IS NULL OR cur!~'^[A-Z]{3}$' OR original_cost IS NULL OR original_cost<=0
  OR accumulated_depreciation IS NULL OR accumulated_depreciation<0 OR accumulated_depreciation>original_cost
  OR source_cost_account IS NULL OR source_depreciation_account IS NULL OR destination_cost_account IS NULL OR destination_depreciation_account IS NULL
  OR jsonb_typeof(cost_evidence)<>'object' OR cost_evidence='{}'::JSONB OR jsonb_typeof(depreciation_evidence)<>'object' OR depreciation_evidence='{}'::JSONB
  OR jsonb_typeof(acceptance_evidence)<>'object' OR acceptance_evidence='{}'::JSONB OR acceptance_evidence->>'destination_group_id' IS DISTINCT FROM destination_group::TEXT
  OR char_length(trim(COALESCE(acceptance_evidence->>'reference',''))) NOT BETWEEN 2 AND 160
  OR effective IS NULL OR period_id IS NULL OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_FACTS_INVALID'; END IF;
 SELECT * INTO r FROM group_shared_asset_transfer_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL OR r.state<>'approved' OR r.transfer_method<>'group' OR r.approved_by IS NULL OR r.created_by=r.approved_by
  OR r.destination->>'group_id' IS DISTINCT FROM destination_group::TEXT THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_APPROVAL_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM group_asset_transfer_accounting_facts WHERE transfer_request_id=r.id) THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_ALREADY_RECORDED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM groups WHERE id=destination_group AND organization_id=o AND lifecycle_state='active') THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_DESTINATION_INVALID'; END IF;
 SELECT * INTO period FROM accounting_periods WHERE id=period_id AND organization_id=o;
 IF period.id IS NULL OR period.status<>'open' OR effective NOT BETWEEN period.starts_on AND period.ends_on THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_ACCOUNTING_PERIOD_INVALID'; END IF;
 SELECT * INTO source_cost FROM financial_accounts WHERE id=source_cost_account AND organization_id=o AND currency=cur AND purpose='shared_asset_cost' AND owner_type='group' AND owner_id=g AND status='active';
 SELECT * INTO source_depreciation FROM financial_accounts WHERE id=source_depreciation_account AND organization_id=o AND currency=cur AND purpose='accumulated_depreciation' AND owner_type='group' AND owner_id=g AND status='active';
 SELECT * INTO destination_cost FROM financial_accounts WHERE id=destination_cost_account AND organization_id=o AND currency=cur AND purpose='shared_asset_cost' AND owner_type='group' AND owner_id=destination_group AND status='active';
 SELECT * INTO destination_depreciation FROM financial_accounts WHERE id=destination_depreciation_account AND organization_id=o AND currency=cur AND purpose='accumulated_depreciation' AND owner_type='group' AND owner_id=destination_group AND status='active';
 IF source_cost.id IS NULL OR source_depreciation.id IS NULL OR destination_cost.id IS NULL OR destination_depreciation.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_LEDGER_ACCOUNTS_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='book_value_transfer' AND version=1 AND execution_enabled=TRUE) THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_MAPPING_UNAVAILABLE'; END IF;
 PERFORM set_config('microfams.group_asset_transfer_accounting_engine','on',TRUE);
 INSERT INTO group_asset_transfer_accounting_facts(organization_id,source_group_id,destination_group_id,asset_id,transfer_request_id,currency,original_cost_minor,accumulated_depreciation_minor,carrying_value_minor,source_asset_cost_account_id,source_accumulated_depreciation_account_id,destination_asset_cost_account_id,destination_accumulated_depreciation_account_id,cost_ledger_evidence,depreciation_ledger_evidence,destination_acceptance_evidence,effective_date,accounting_period_id,maker_id,checker_id,recorded_by,idempotency_key,fact_hash,correlation_id,recorded_at)
 VALUES(o,g,destination_group,r.asset_id,r.id,cur,original_cost,accumulated_depreciation,original_cost-accumulated_depreciation,source_cost_account,source_depreciation_account,destination_cost_account,destination_depreciation_account,cost_evidence,depreciation_evidence,acceptance_evidence,effective,period_id,r.created_by,r.approved_by,a,idem,h,corr,at_time) RETURNING id INTO fact_id;
 INSERT INTO group_asset_transfer_accounting_events(organization_id,source_group_id,destination_group_id,asset_id,transfer_request_id,accounting_facts_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,destination_group,r.asset_id,r.id,fact_id,a,'TRANSFER_ACCOUNTING_FACTS_RECORDED',corr,jsonb_build_object('mapping_key','book_value_transfer','mapping_version',1,'currency',cur,'original_cost_minor',original_cost,'accumulated_depreciation_minor',accumulated_depreciation,'carrying_value_minor',original_cost-accumulated_depreciation,'accounting_period_id',period_id,'destination_acceptance_evidence',acceptance_evidence,'reconciliation_status','pending','execution_enabled',true),at_time);
 PERFORM set_config('microfams.group_asset_transfer_accounting_engine','',TRUE); RETURN fact_id;
END $$;

ALTER TABLE group_shared_asset_transfer_requests ADD COLUMN executed_by UUID REFERENCES users(id), ADD COLUMN executed_at TIMESTAMPTZ, ADD COLUMN execution_journal_entry_id UUID REFERENCES journal_entries(id);
ALTER TABLE group_shared_asset_transfer_requests DROP CONSTRAINT IF EXISTS group_shared_asset_transfer_requests_state_check;
ALTER TABLE group_shared_asset_transfer_requests DROP CONSTRAINT IF EXISTS group_shared_asset_transfer_requests_check;
ALTER TABLE group_shared_asset_transfer_requests ADD CONSTRAINT group_shared_asset_transfer_requests_state_check CHECK(state IN('draft','proposed','approved','executed','cancelled'));
ALTER TABLE group_shared_asset_transfer_requests ADD CONSTRAINT group_shared_asset_transfer_approval_consistency CHECK((state IN('approved','executed'))=(approved_by IS NOT NULL AND approved_at IS NOT NULL));
ALTER TABLE group_shared_asset_transfer_requests ADD CONSTRAINT group_shared_asset_transfer_execution_consistency CHECK((state='executed')=(executed_by IS NOT NULL AND executed_at IS NOT NULL AND execution_journal_entry_id IS NOT NULL));
ALTER TABLE group_shared_asset_transfer_events DROP CONSTRAINT IF EXISTS group_shared_asset_transfer_events_event_type_check;
ALTER TABLE group_shared_asset_transfer_events ADD CONSTRAINT group_shared_asset_transfer_events_event_type_check CHECK(event_type IN('TRANSFER_REQUESTED','TRANSFER_SUBMITTED','TRANSFER_APPROVED','TRANSFER_EXECUTED'));
ALTER TABLE group_shared_asset_events DROP CONSTRAINT IF EXISTS group_shared_asset_events_event_type_check;
ALTER TABLE group_shared_asset_events ADD CONSTRAINT group_shared_asset_events_event_type_check CHECK(event_type IN('ASSET_REGISTERED','ASSET_DISPOSED','ASSET_TRANSFERRED'));

CREATE TABLE group_asset_transfer_executions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 source_group_id UUID NOT NULL REFERENCES groups(id), destination_group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 transfer_request_id UUID NOT NULL UNIQUE REFERENCES group_shared_asset_transfer_requests(id), accounting_facts_id UUID NOT NULL UNIQUE REFERENCES group_asset_transfer_accounting_facts(id),
 journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id), destination_custodian_member_id UUID NOT NULL REFERENCES group_members(id), destination_location JSONB NOT NULL CHECK(jsonb_typeof(destination_location)='object'),
 reconciliation_status TEXT NOT NULL DEFAULT 'pending' CHECK(reconciliation_status IN('pending','reconciled','exception')),
 executed_by UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL, execution_hash VARCHAR(64) NOT NULL CHECK(execution_hash~'^[a-f0-9]{64}$'),
 correlation_id UUID NOT NULL, executed_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id), CHECK(source_group_id<>destination_group_id)
);
ALTER TABLE group_asset_transfer_executions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_asset_transfer_executions FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_asset_transfer_executions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_asset_transfer_executions TO service_role;
CREATE OR REPLACE FUNCTION protect_group_asset_transfer_execution() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('microfams.group_asset_transfer_execution_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_ENGINE_REQUIRED';
END $$;
CREATE TRIGGER protect_group_asset_transfer_execution BEFORE INSERT OR UPDATE OR DELETE ON group_asset_transfer_executions FOR EACH ROW EXECUTE FUNCTION protect_group_asset_transfer_execution();

CREATE OR REPLACE FUNCTION execute_group_shared_asset_transfer(o UUID,g UUID,a UUID,request_id UUID,destination_custodian UUID,destination_location JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_transfer_requests; asset group_shared_assets; f group_asset_transfer_accounting_facts; existing group_asset_transfer_executions;
 cost_balance BIGINT; depreciation_balance BIGINT; lines JSONB:='[]'::JSONB; n INTEGER:=0; h TEXT; journal UUID; execution_id UUID;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) OR NOT has_financial_permission(o,a,'financial.accounts.manage') THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_PERMISSION_DENIED'; END IF;
 SELECT * INTO r FROM group_shared_asset_transfer_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO f FROM group_asset_transfer_accounting_facts WHERE transfer_request_id=request_id AND organization_id=o FOR UPDATE;
 IF r.id IS NULL OR f.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_FACTS_REQUIRED'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,r.id,f.id,f.fact_hash,destination_custodian,destination_location::TEXT,idem),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-transfer-execution:'||idem,0));
 SELECT * INTO existing FROM group_asset_transfer_executions WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN IF existing.execution_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_IDEMPOTENCY_CONFLICT'; END IF; RETURN existing.id; END IF;
 IF r.state<>'approved' OR r.transfer_method<>'group' OR f.reconciliation_status<>'pending' OR f.source_group_id<>g OR f.destination_group_id::TEXT IS DISTINCT FROM r.destination->>'group_id'
  OR jsonb_typeof(destination_location)<>'object' OR destination_location='{}'::JSONB OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_STATE_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_members m WHERE m.id=destination_custodian AND m.organization_id=o AND m.group_id=f.destination_group_id AND m.status='active' AND m.is_active=TRUE) THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_DESTINATION_CUSTODIAN_INVALID'; END IF;
 SELECT * INTO asset FROM group_shared_assets WHERE id=r.asset_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF asset.id IS NULL OR asset.lifecycle_state<>'active' OR asset.availability_state NOT IN('available','unavailable') OR EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=asset.id AND x.state IN('requested','confirmed','checked_out'))
  OR EXISTS(SELECT 1 FROM group_shared_assets x WHERE x.organization_id=o AND x.group_id=f.destination_group_id AND x.asset_key=asset.asset_key AND x.id<>asset.id) THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_ASSET_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE id=f.accounting_period_id AND organization_id=o AND status='open' AND f.effective_date BETWEEN starts_on AND ends_on)
  OR NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key=f.mapping_key AND version=f.mapping_version AND execution_enabled=TRUE) THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_EXECUTION_ACCOUNTING_INVALID'; END IF;
 SELECT COALESCE(sum(CASE WHEN line.side='debit' THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT INTO cost_balance FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id WHERE line.organization_id=o AND line.account_id=f.source_asset_cost_account_id AND entry.status='posted';
 SELECT COALESCE(sum(CASE WHEN line.side='credit' THEN line.amount_minor ELSE -line.amount_minor END),0)::BIGINT INTO depreciation_balance FROM journal_lines line JOIN journal_entries entry ON entry.id=line.journal_entry_id WHERE line.organization_id=o AND line.account_id=f.source_accumulated_depreciation_account_id AND entry.status='posted';
 IF cost_balance<>f.original_cost_minor OR depreciation_balance<>f.accumulated_depreciation_minor THEN RAISE EXCEPTION 'GROUP_ASSET_TRANSFER_LEDGER_BALANCES_INVALID'; END IF;
 IF f.accumulated_depreciation_minor>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.source_accumulated_depreciation_account_id,'line_number',n,'side','debit','amount_minor',f.accumulated_depreciation_minor)); END IF;
 n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.destination_asset_cost_account_id,'line_number',n,'side','debit','amount_minor',f.original_cost_minor));
 n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.source_asset_cost_account_id,'line_number',n,'side','credit','amount_minor',f.original_cost_minor));
 IF f.accumulated_depreciation_minor>0 THEN n:=n+1; lines:=lines||jsonb_build_array(jsonb_build_object('account_id',f.destination_accumulated_depreciation_account_id,'line_number',n,'side','credit','amount_minor',f.accumulated_depreciation_minor)); END IF;
 journal:=post_financial_journal(o,f.currency,f.effective_date,'groups.asset_transfer',r.id::TEXT,idem,h,corr,'Transfer shared asset '||asset.name,a,lines);
 PERFORM set_config('microfams.group_asset_transfer_execution_engine','on',TRUE);
 INSERT INTO group_asset_transfer_executions(organization_id,source_group_id,destination_group_id,asset_id,transfer_request_id,accounting_facts_id,journal_entry_id,destination_custodian_member_id,destination_location,executed_by,idempotency_key,execution_hash,correlation_id,executed_at)
 VALUES(o,g,f.destination_group_id,asset.id,r.id,f.id,journal,destination_custodian,destination_location,a,idem,h,corr,at_time) RETURNING id INTO execution_id;
 PERFORM set_config('microfams.group_shared_asset_transfer_engine','on',TRUE); PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_transfer_requests SET state='executed',executed_by=a,executed_at=at_time,execution_journal_entry_id=journal,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET group_id=f.destination_group_id,custodian_member_id=destination_custodian,location=destination_location,updated_at=at_time WHERE id=asset.id;
 INSERT INTO group_shared_asset_transfer_events(organization_id,group_id,asset_id,transfer_request_id,actor_id,event_type,proposal_id,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset.id,r.id,a,'TRANSFER_EXECUTED',r.proposal_id,corr,jsonb_build_object('source_group_id',g,'destination_group_id',f.destination_group_id,'accounting_facts_id',f.id,'journal_entry_id',journal,'destination_custodian_member_id',destination_custodian,'reconciliation_status','pending'),at_time);
 INSERT INTO group_shared_asset_events(organization_id,group_id,asset_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,f.destination_group_id,asset.id,a,'ASSET_TRANSFERRED',gen_random_uuid(),jsonb_build_object('source_group_id',g,'destination_group_id',f.destination_group_id,'transfer_request_id',r.id,'execution_id',execution_id,'journal_entry_id',journal),at_time);
 PERFORM set_config('microfams.group_shared_asset_transfer_engine','',TRUE); PERFORM set_config('microfams.group_shared_asset_engine','',TRUE); PERFORM set_config('microfams.group_asset_transfer_execution_engine','',TRUE);
 RETURN execution_id;
END $$;
REVOKE ALL ON FUNCTION execute_group_shared_asset_transfer(UUID,UUID,UUID,UUID,UUID,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION execute_group_shared_asset_transfer(UUID,UUID,UUID,UUID,UUID,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
REVOKE INSERT,UPDATE,DELETE ON group_asset_transfer_executions FROM service_role;
