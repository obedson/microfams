BEGIN;
DO $$
<<fixture>>
DECLARE org UUID; owner UUID; manager UUID; source_group UUID; destination_group UUID; source_owner_member UUID; source_manager_member UUID;
 destination_owner_member UUID; destination_manager_member UUID; asset_id UUID; request_id UUID; proposal_id UUID; period_id UUID;
 source_cost UUID; source_depreciation UUID; destination_cost UUID; destination_depreciation UUID; facts_id UUID; replay_id UUID;
 journals_before BIGINT; acceptance JSONB;
BEGIN
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('gt10o-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10O Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage','groups.proposals.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10O Source','cooperative',owner,org,10) RETURNING id INTO source_group;
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10O Destination','cooperative',owner,org,10) RETURNING id INTO destination_group;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,source_group,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO source_owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,source_group,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO source_manager_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,destination_group,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO destination_owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,destination_group,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO destination_manager_member;
 PERFORM adopt_initial_group_constitution(org,source_group,owner,'GT10O Source Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000002201','2026-08-28T08:00:00Z');
 PERFORM appoint_initial_group_office(org,source_group,owner,'chair',source_owner_member,NULL,'00000000-0000-4000-8000-000000002202','2026-08-28T08:01:00Z');
 PERFORM appoint_initial_group_office(org,source_group,owner,'secretary',source_owner_member,NULL,'00000000-0000-4000-8000-000000002203','2026-08-28T08:02:00Z');
 PERFORM appoint_initial_group_office(org,source_group,owner,'treasurer',source_owner_member,NULL,'00000000-0000-4000-8000-000000002204','2026-08-28T08:03:00Z');
 PERFORM activate_group_with_constitution(org,source_group,owner,1,'00000000-0000-4000-8000-000000002205','2026-08-28T08:04:00Z');
 PERFORM adopt_initial_group_constitution(org,destination_group,owner,'GT10O Destination Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000002206','2026-08-28T08:05:00Z');
 PERFORM appoint_initial_group_office(org,destination_group,owner,'chair',destination_owner_member,NULL,'00000000-0000-4000-8000-000000002207','2026-08-28T08:06:00Z');
 PERFORM appoint_initial_group_office(org,destination_group,owner,'secretary',destination_owner_member,NULL,'00000000-0000-4000-8000-000000002208','2026-08-28T08:07:00Z');
 PERFORM appoint_initial_group_office(org,destination_group,owner,'treasurer',destination_owner_member,NULL,'00000000-0000-4000-8000-000000002209','2026-08-28T08:08:00Z');
 PERFORM activate_group_with_constitution(org,destination_group,owner,1,'00000000-0000-4000-8000-000000002210','2026-08-28T08:09:00Z');
 asset_id:=register_group_shared_asset(org,source_group,manager,'pump_10o','GT10O Pump','farm_equipment','{"type":"purchase"}',source_manager_member,'{"label":"Source shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10o-asset','00000000-0000-4000-8000-000000002211','2026-08-28T08:10:00Z');
 request_id:=create_group_shared_asset_transfer(org,source_group,manager,asset_id,'group',jsonb_build_object('group_id',destination_group,'reference','destination-acceptance-10o'),'Transfer at book value','[{"kind":"transfer_agreement","reference":"transfer-10o"}]','gt10o-transfer','00000000-0000-4000-8000-000000002212','2026-08-28T08:11:00Z');
 proposal_id:=create_group_proposal(org,source_group,manager,'shared_asset_action','Transfer GT10O pump','[]',jsonb_build_object('action','transfer','asset_id',asset_id,'transfer_id',request_id),'{}','2026-08-28T08:12:00Z','2026-08-28T08:15:00Z','00000000-0000-4000-8000-000000002213','2026-08-28T08:12:00Z');
 PERFORM submit_group_shared_asset_transfer(org,source_group,manager,request_id,proposal_id,'00000000-0000-4000-8000-000000002214','2026-08-28T08:12:30Z');
 PERFORM open_group_proposal(org,source_group,owner,proposal_id,1,'00000000-0000-4000-8000-000000002215','2026-08-28T08:13:00Z');
 PERFORM cast_group_proposal_vote(org,source_group,owner,proposal_id,'approve','00000000-0000-4000-8000-000000002216','2026-08-28T08:13:30Z');
 PERFORM close_group_proposal(org,source_group,owner,proposal_id,2,'00000000-0000-4000-8000-000000002217','2026-08-28T08:15:00Z');
 PERFORM approve_group_shared_asset_transfer(org,source_group,owner,request_id,'00000000-0000-4000-8000-000000002218','2026-08-28T08:15:00Z');
 INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'GT10O FY 2029',DATE '2029-01-01',DATE '2029-12-31','open') RETURNING id INTO period_id;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10O.SRC.COST','GT10O source asset cost','asset','debit','NGN','group',source_group,TRUE,owner,'shared_asset_cost') RETURNING id INTO source_cost;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10O.SRC.DEP','GT10O source depreciation','asset','credit','NGN','group',source_group,TRUE,owner,'accumulated_depreciation') RETURNING id INTO source_depreciation;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10O.DST.COST','GT10O destination asset cost','asset','debit','NGN','group',destination_group,TRUE,owner,'shared_asset_cost') RETURNING id INTO destination_cost;
 INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,created_by,purpose) VALUES
  (org,'GT10O.DST.DEP','GT10O destination depreciation','asset','credit','NGN','group',destination_group,TRUE,owner,'accumulated_depreciation') RETURNING id INTO destination_depreciation;
 acceptance:=jsonb_build_object('destination_group_id',destination_group,'reference','accepted-10o','accepted_at','2029-01-15T09:00:00Z');
 SELECT count(*) INTO journals_before FROM journal_entries;
 facts_id:=record_group_asset_transfer_accounting_facts(org,source_group,owner,request_id,destination_group,'ngn',120000,30000,source_cost,source_depreciation,destination_cost,destination_depreciation,'{"journal_entry_id":"cost-source-10o"}','{"journal_entry_id":"depreciation-source-10o"}',acceptance,DATE '2029-01-15',period_id,'gt10o-transfer-facts','00000000-0000-4000-8000-000000002219','2029-01-15T10:00:00Z');
 replay_id:=record_group_asset_transfer_accounting_facts(org,source_group,owner,request_id,destination_group,'NGN',120000,30000,source_cost,source_depreciation,destination_cost,destination_depreciation,'{"journal_entry_id":"cost-source-10o"}','{"journal_entry_id":"depreciation-source-10o"}',acceptance,DATE '2029-01-15',period_id,'gt10o-transfer-facts','00000000-0000-4000-8000-000000002219','2029-01-15T10:00:00Z');
 IF replay_id<>facts_id THEN RAISE EXCEPTION 'GT10O transfer facts replay created a duplicate'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_transfer_accounting_facts f WHERE f.id=facts_id AND f.mapping_key='book_value_transfer' AND f.mapping_version=1 AND f.source_group_id=source_group AND f.destination_group_id=destination_group AND f.currency='NGN' AND f.carrying_value_minor=90000 AND f.maker_id=manager AND f.checker_id=owner AND f.reconciliation_status='pending') THEN RAISE EXCEPTION 'GT10O transfer accounting facts are invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_transfer_accounting_events e WHERE e.accounting_facts_id=facts_id AND e.evidence->>'execution_enabled'='false' AND e.evidence->'destination_acceptance_evidence'=acceptance) THEN RAISE EXCEPTION 'GT10O transfer accounting evidence is incomplete'; END IF;
 IF (SELECT count(*) FROM journal_entries)<>journals_before OR NOT EXISTS(SELECT 1 FROM group_shared_assets a WHERE a.id=asset_id AND a.group_id=source_group AND a.lifecycle_state='active' AND a.availability_state='available') OR EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='book_value_transfer' AND execution_enabled) THEN RAISE EXCEPTION 'GT10O facts recording crossed the execution boundary'; END IF;
 BEGIN PERFORM record_group_asset_transfer_accounting_facts(org,source_group,owner,request_id,destination_group,'NGN',120001,30000,source_cost,source_depreciation,destination_cost,destination_depreciation,'{"journal_entry_id":"cost-source-10o"}','{"journal_entry_id":"depreciation-source-10o"}',acceptance,DATE '2029-01-15',period_id,'gt10o-transfer-facts','00000000-0000-4000-8000-000000002219','2029-01-15T10:00:00Z'); RAISE EXCEPTION 'changed transfer facts replay was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='changed transfer facts replay was accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_TRANSFER_ACCOUNTING_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 IF has_table_privilege('service_role','group_asset_transfer_accounting_facts','INSERT') OR pg_get_functiondef('record_group_asset_transfer_accounting_facts(uuid,uuid,uuid,uuid,uuid,text,bigint,bigint,uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb,date,uuid,text,uuid,timestamp with time zone)'::regprocedure) LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10O transfer accounting boundary is unsafe'; END IF;
END $$;
SELECT 'group asset transfer accounting facts schema tests passed' AS result;
ROLLBACK;
