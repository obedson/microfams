BEGIN;
DO $$
<<fixture>>
DECLARE org UUID; owner UUID; manager UUID; gid UUID; owner_member UUID; manager_member UUID; asset_id UUID; request_id UUID; proposal_id UUID;
 period_id UUID; cost_account UUID; depreciation_account UUID; proceeds_account UUID; facts_id UUID; replay_id UUID; journals_before BIGINT;
BEGIN
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('gt10m-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10M Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage','groups.proposals.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10M Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10M Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000002001','2026-08-26T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000002002','2026-08-26T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000002003','2026-08-26T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000002004','2026-08-26T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000002005','2026-08-26T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_10m','GT10M Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10m-asset','00000000-0000-4000-8000-000000002006','2026-08-26T08:05:00Z');
 request_id:=create_group_shared_asset_disposal(org,gid,manager,asset_id,'sale','Sell asset after approved cooperative review','[{"kind":"valuation","reference":"val-10m"}]','gt10m-disposal','00000000-0000-4000-8000-000000002007','2026-08-26T08:06:00Z');
 proposal_id:=create_group_proposal(org,gid,manager,'shared_asset_action','Dispose GT10M tractor','[]',jsonb_build_object('action','dispose','asset_id',asset_id,'disposal_id',request_id),'{}','2026-08-26T08:07:00Z','2026-08-26T08:10:00Z','00000000-0000-4000-8000-000000002008','2026-08-26T08:07:00Z');
 PERFORM submit_group_shared_asset_disposal(org,gid,manager,request_id,proposal_id,'00000000-0000-4000-8000-000000002009','2026-08-26T08:07:30Z');
 PERFORM open_group_proposal(org,gid,owner,proposal_id,1,'00000000-0000-4000-8000-000000002010','2026-08-26T08:08:00Z');
 PERFORM cast_group_proposal_vote(org,gid,owner,proposal_id,'approve','00000000-0000-4000-8000-000000002011','2026-08-26T08:08:30Z');
 PERFORM close_group_proposal(org,gid,owner,proposal_id,2,'00000000-0000-4000-8000-000000002012','2026-08-26T08:10:00Z');
 PERFORM approve_group_shared_asset_disposal(org,gid,owner,request_id,'00000000-0000-4000-8000-000000002013','2026-08-26T08:10:00Z');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'GT10M FY 2027',DATE '2027-01-01',DATE '2027-12-31','open') RETURNING id INTO period_id;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10M.COST','GT10M asset cost','asset','debit','NGN','group',gid,TRUE,owner,'shared_asset_cost') RETURNING id INTO cost_account;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10M.DEP','GT10M accumulated depreciation','asset','credit','NGN','group',gid,TRUE,owner,'accumulated_depreciation') RETURNING id INTO depreciation_account;
 SELECT id INTO proceeds_account FROM financial_accounts WHERE organization_id=org AND purpose='operating_cash' AND currency='NGN' AND status='active' ORDER BY created_at LIMIT 1;
 SELECT count(*) INTO journals_before FROM journal_entries;
 facts_id:=record_group_asset_disposal_accounting_facts(org,gid,owner,request_id,'ngn',100000,25000,90000,cost_account,depreciation_account,proceeds_account,'{"journal_entry_id":"cost-source-10m"}','{"journal_entry_id":"depreciation-source-10m"}','[{"kind":"bank_receipt","reference":"receipt-10m"}]',DATE '2027-01-15',period_id,'gt10m-accounting-facts','00000000-0000-4000-8000-000000002014','2027-01-15T10:00:00Z');
 replay_id:=record_group_asset_disposal_accounting_facts(org,gid,owner,request_id,'NGN',100000,25000,90000,cost_account,depreciation_account,proceeds_account,'{"journal_entry_id":"cost-source-10m"}','{"journal_entry_id":"depreciation-source-10m"}','[{"kind":"bank_receipt","reference":"receipt-10m"}]',DATE '2027-01-15',period_id,'gt10m-accounting-facts','00000000-0000-4000-8000-000000002014','2027-01-15T10:00:00Z');
 IF replay_id<>facts_id THEN RAISE EXCEPTION 'GT10M accounting facts replay created a duplicate'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_disposal_accounting_facts WHERE id=facts_id AND mapping_key='disposal_with_proceeds' AND mapping_version=1 AND currency='NGN' AND carrying_value_minor=75000 AND maker_id=manager AND checker_id=owner AND reconciliation_status='pending') THEN RAISE EXCEPTION 'GT10M accounting facts are invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_disposal_accounting_events WHERE accounting_facts_id=facts_id AND evidence->>'execution_enabled'='false') THEN RAISE EXCEPTION 'GT10M accounting evidence is incomplete'; END IF;
 IF (SELECT count(*) FROM journal_entries)<>journals_before OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='active' AND availability_state='available') THEN RAISE EXCEPTION 'GT10M facts recording mutated journals or asset state'; END IF;
 BEGIN PERFORM record_group_asset_disposal_accounting_facts(org,gid,owner,request_id,'NGN',100001,25000,90000,cost_account,depreciation_account,proceeds_account,'{"journal_entry_id":"cost-source-10m"}','{"journal_entry_id":"depreciation-source-10m"}','[{"kind":"bank_receipt","reference":"receipt-10m"}]',DATE '2027-01-15',period_id,'gt10m-accounting-facts','00000000-0000-4000-8000-000000002014','2027-01-15T10:00:00Z'); RAISE EXCEPTION 'changed accounting facts replay was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='changed accounting facts replay was accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_DISPOSAL_ACCOUNTING_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 IF has_table_privilege('service_role','group_asset_disposal_accounting_facts','INSERT') OR pg_get_functiondef('record_group_asset_disposal_accounting_facts(uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,uuid,uuid,uuid,jsonb,jsonb,jsonb,date,uuid,text,uuid,timestamp with time zone)'::regprocedure) LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10M accounting boundary is unsafe'; END IF;
END $$;
SELECT 'group asset disposal accounting facts schema tests passed' AS result;
ROLLBACK;
