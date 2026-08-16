BEGIN;
DO $$
<<fixture>>
DECLARE org UUID; owner UUID; manager UUID; gid UUID; owner_member UUID; manager_member UUID; asset_id UUID; request_id UUID; proposal_id UUID; period_id UUID;
 cost_account UUID; depreciation_account UUID; proceeds_account UUID; gain_account UUID; offset_account UUID; facts_id UUID; execution_id UUID; replay_id UUID;
 journal_id UUID; source_journal_id UUID;
BEGIN
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('gt10n-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10N Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage','groups.proposals.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10N Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10N Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000002101','2026-08-27T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000002102','2026-08-27T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000002103','2026-08-27T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000002104','2026-08-27T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000002105','2026-08-27T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_10n','GT10N Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10n-asset','00000000-0000-4000-8000-000000002106','2026-08-27T08:05:00Z');
 request_id:=create_group_shared_asset_disposal(org,gid,manager,asset_id,'sale','Execute approved asset sale','[{"kind":"valuation","reference":"val-10n"}]','gt10n-disposal','00000000-0000-4000-8000-000000002107','2026-08-27T08:06:00Z');
 proposal_id:=create_group_proposal(org,gid,manager,'shared_asset_action','Dispose GT10N tractor','[]',jsonb_build_object('action','dispose','asset_id',asset_id,'disposal_id',request_id),'{}','2026-08-27T08:07:00Z','2026-08-27T08:10:00Z','00000000-0000-4000-8000-000000002108','2026-08-27T08:07:00Z');
 PERFORM submit_group_shared_asset_disposal(org,gid,manager,request_id,proposal_id,'00000000-0000-4000-8000-000000002109','2026-08-27T08:07:30Z');
 PERFORM open_group_proposal(org,gid,owner,proposal_id,1,'00000000-0000-4000-8000-000000002110','2026-08-27T08:08:00Z');
 PERFORM cast_group_proposal_vote(org,gid,owner,proposal_id,'approve','00000000-0000-4000-8000-000000002111','2026-08-27T08:08:30Z');
 PERFORM close_group_proposal(org,gid,owner,proposal_id,2,'00000000-0000-4000-8000-000000002112','2026-08-27T08:10:00Z');
 PERFORM approve_group_shared_asset_disposal(org,gid,owner,request_id,'00000000-0000-4000-8000-000000002113','2026-08-27T08:10:00Z');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'GT10N FY 2028',DATE '2028-01-01',DATE '2028-12-31','open') RETURNING id INTO period_id;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10N.COST','GT10N asset cost','asset','debit','NGN','group',gid,TRUE,owner,'shared_asset_cost') RETURNING id INTO cost_account;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10N.DEP','GT10N accumulated depreciation','asset','credit','NGN','group',gid,TRUE,owner,'accumulated_depreciation') RETURNING id INTO depreciation_account;
 SELECT id INTO proceeds_account FROM financial_accounts WHERE organization_id=org AND purpose='operating_cash' AND currency='NGN' AND status='active' ORDER BY created_at LIMIT 1;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10N.GAIN','GT10N disposal gain','revenue','credit','NGN','group',gid,FALSE,owner,'asset_disposal_gain') RETURNING id INTO gain_account;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by) VALUES
  (org,'GT10N.OFFSET','GT10N opening equity','equity','credit','NGN','organization',NULL,FALSE,owner) RETURNING id INTO offset_account;
 source_journal_id:=post_financial_journal(org,'NGN',DATE '2028-01-14','groups.asset_source',asset_id::TEXT,'gt10n-asset-source',repeat('a',64),'00000000-0000-4000-8000-000000002114','Seed asset ledger balances',owner,jsonb_build_array(
  jsonb_build_object('account_id',cost_account,'line_number',1,'side','debit','amount_minor',90000),
  jsonb_build_object('account_id',depreciation_account,'line_number',2,'side','credit','amount_minor',20000),
  jsonb_build_object('account_id',offset_account,'line_number',3,'side','credit','amount_minor',70000)));
 facts_id:=record_group_asset_disposal_accounting_facts(org,gid,owner,request_id,'NGN',100000,25000,90000,cost_account,depreciation_account,proceeds_account,jsonb_build_object('journal_entry_id',source_journal_id),jsonb_build_object('journal_entry_id',source_journal_id),'[{"kind":"bank_receipt","reference":"receipt-10n"}]',DATE '2028-01-15',period_id,'gt10n-accounting-facts','00000000-0000-4000-8000-000000002115','2028-01-15T09:00:00Z');
 BEGIN
  PERFORM execute_group_shared_asset_disposal(org,gid,owner,request_id,gain_account,'gt10n-disposal-execution','00000000-0000-4000-8000-000000002116','2028-01-15T10:00:00Z');
  RAISE EXCEPTION 'GT10N execution accepted unsupported ledger facts';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE '%GROUP_ASSET_DISPOSAL_LEDGER_BALANCES_INVALID%' THEN RAISE; END IF;
 END;
 PERFORM post_financial_journal(org,'NGN',DATE '2028-01-14','groups.asset_source',asset_id::TEXT,'gt10n-asset-adjustment',repeat('b',64),'00000000-0000-4000-8000-000000002117','Adjust asset ledger balances',owner,jsonb_build_array(
  jsonb_build_object('account_id',cost_account,'line_number',1,'side','debit','amount_minor',10000),
  jsonb_build_object('account_id',depreciation_account,'line_number',2,'side','credit','amount_minor',5000),
  jsonb_build_object('account_id',offset_account,'line_number',3,'side','credit','amount_minor',5000)));
 execution_id:=execute_group_shared_asset_disposal(org,gid,owner,request_id,gain_account,'gt10n-disposal-execution','00000000-0000-4000-8000-000000002116','2028-01-15T10:00:00Z');
 replay_id:=execute_group_shared_asset_disposal(org,gid,owner,request_id,gain_account,'gt10n-disposal-execution','00000000-0000-4000-8000-000000002116','2028-01-15T10:00:00Z');
 IF replay_id<>execution_id THEN RAISE EXCEPTION 'GT10N execution replay created a duplicate'; END IF;
 SELECT journal_entry_id INTO journal_id FROM group_asset_disposal_executions WHERE id=execution_id;
 IF NOT EXISTS(SELECT 1 FROM group_asset_disposal_executions WHERE id=execution_id AND accounting_facts_id=facts_id AND disposal_gain_minor=15000 AND disposal_loss_minor=0 AND reconciliation_status='pending') THEN RAISE EXCEPTION 'GT10N execution evidence is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_disposal_requests WHERE id=request_id AND state='executed' AND execution_journal_entry_id=journal_id) OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='disposed' AND availability_state='unavailable') THEN RAISE EXCEPTION 'GT10N execution did not finalize lifecycle'; END IF;
 IF (SELECT count(*) FROM journal_lines WHERE journal_entry_id=journal_id)<>4 OR (SELECT sum(CASE WHEN side='debit' THEN amount_minor ELSE -amount_minor END) FROM journal_lines WHERE journal_entry_id=journal_id)<>0 THEN RAISE EXCEPTION 'GT10N disposal journal is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=journal_id AND account_id=proceeds_account AND side='debit' AND amount_minor=90000) OR NOT EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=journal_id AND account_id=depreciation_account AND side='debit' AND amount_minor=25000) OR NOT EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=journal_id AND account_id=cost_account AND side='credit' AND amount_minor=100000) OR NOT EXISTS(SELECT 1 FROM journal_lines WHERE journal_entry_id=journal_id AND account_id=gain_account AND side='credit' AND amount_minor=15000) THEN RAISE EXCEPTION 'GT10N journal mapping is invalid'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_disposal_events disposal_event WHERE disposal_event.disposal_request_id=fixture.request_id)<>4 OR NOT EXISTS(SELECT 1 FROM group_shared_asset_events asset_event WHERE asset_event.asset_id=fixture.asset_id AND asset_event.event_type='ASSET_DISPOSED') THEN RAISE EXCEPTION 'GT10N lifecycle evidence is incomplete'; END IF;
 IF has_table_privilege('service_role','group_asset_disposal_executions','INSERT') THEN RAISE EXCEPTION 'service role can forge disposal execution'; END IF;
END $$;
SELECT 'group asset disposal execution schema tests passed' AS result;
ROLLBACK;
