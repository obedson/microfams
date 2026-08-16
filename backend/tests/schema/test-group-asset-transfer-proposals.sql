BEGIN;
DO $$
<<fixture>>
DECLARE org UUID; owner UUID; manager UUID; gid UUID; owner_member UUID; manager_member UUID; asset_id UUID; request_id UUID; proposal_id UUID;
BEGIN
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('gt10k-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10K Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage','groups.proposals.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10K Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10K Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001901','2026-08-25T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001902','2026-08-25T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001903','2026-08-25T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001904','2026-08-25T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001905','2026-08-25T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'pump_10k','GT10K Pump','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10k-asset','00000000-0000-4000-8000-000000001906','2026-08-25T08:05:00Z');
 request_id:=create_group_shared_asset_transfer(org,gid,manager,asset_id,'group','{"group_reference":"destination-group-01","custodian_reference":"member-02"}','Move asset to another cooperative group','[{"kind":"transfer_agreement","reference":"transfer-10k"}]','gt10k-transfer','00000000-0000-4000-8000-000000001907','2026-08-25T08:06:00Z');
 BEGIN PERFORM approve_group_shared_asset_transfer(org,gid,owner,request_id,'00000000-0000-4000-8000-000000001908','2026-08-25T08:07:00Z'); RAISE EXCEPTION 'unsubmitted transfer approved'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='unsubmitted transfer approved' OR SQLERRM NOT LIKE '%GROUP_ASSET_TRANSFER_APPROVAL_REQUIRED%' THEN RAISE; END IF; END;
 proposal_id:=create_group_proposal(org,gid,manager,'shared_asset_action','Transfer GT10K pump to another group','[]',jsonb_build_object('action','transfer','asset_id',asset_id,'transfer_id',request_id),'{}','2026-08-25T08:07:00Z','2026-08-25T08:10:00Z','00000000-0000-4000-8000-000000001909','2026-08-25T08:07:00Z');
 PERFORM submit_group_shared_asset_transfer(org,gid,manager,request_id,proposal_id,'00000000-0000-4000-8000-000000001910','2026-08-25T08:07:30Z');
 PERFORM open_group_proposal(org,gid,owner,proposal_id,1,'00000000-0000-4000-8000-000000001911','2026-08-25T08:08:00Z');
 PERFORM cast_group_proposal_vote(org,gid,owner,proposal_id,'approve','00000000-0000-4000-8000-000000001912','2026-08-25T08:08:30Z');
 PERFORM close_group_proposal(org,gid,owner,proposal_id,2,'00000000-0000-4000-8000-000000001913','2026-08-25T08:10:00Z');
 PERFORM approve_group_shared_asset_transfer(org,gid,owner,request_id,'00000000-0000-4000-8000-000000001914','2026-08-25T08:10:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_transfer_requests r WHERE r.id=request_id AND r.state='approved' AND r.approved_by=owner AND r.proposal_id=fixture.proposal_id)
  OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='active' AND availability_state='available') THEN RAISE EXCEPTION 'GT10K approval mutated unexpected state'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_transfer_events WHERE transfer_request_id=request_id)=3 THEN NULL; ELSE RAISE EXCEPTION 'GT10K transfer evidence incomplete'; END IF;
END $$;
SELECT 'group asset transfer proposal schema tests passed' AS result;
ROLLBACK;
