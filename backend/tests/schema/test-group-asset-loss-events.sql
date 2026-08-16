BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; outsider UUID; gid UUID;
 owner_member UUID; manager_member UUID; asset_id UUID; committed_asset UUID; reservation_id UUID; loss_id UUID; replay_id UUID;
BEGIN
 IF to_regclass('public.group_shared_asset_loss_events') IS NULL THEN RAISE EXCEPTION 'GT10F loss event table missing'; END IF;
 SELECT pg_get_functiondef('report_group_shared_asset_loss(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%pg_advisory_xact_lock%' OR d NOT LIKE '%group_shared_asset_reservations%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10F loss invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='group_shared_asset_loss_events' AND policyname='tenant_read') THEN RAISE EXCEPTION 'GT10F tenant policy missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10F tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10f-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10F Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10f-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10F Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10F Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10F Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001401','2026-08-19T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001402','2026-08-19T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001403','2026-08-19T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001404','2026-08-19T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001405','2026-08-19T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'pump_10f','GT10F Irrigation Pump','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Pump shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10f-asset-register','00000000-0000-4000-8000-000000001406','2026-08-19T08:05:00Z');
 committed_asset:=register_group_shared_asset(org,gid,manager,'tractor_10f','GT10F Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10f-committed-register','00000000-0000-4000-8000-000000001407','2026-08-19T08:06:00Z');
 BEGIN
  PERFORM report_group_shared_asset_loss(org,gid,outsider,asset_id,'theft','Pump missing from storage','{"label":"Pump shed"}','[{"kind":"incident_photo"}]','gt10f-denied-loss','00000000-0000-4000-8000-000000001408','2026-08-19T08:07:00Z');
  RAISE EXCEPTION 'unauthorized loss report accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized loss report accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 reservation_id:=request_group_shared_asset_reservation(org,gid,manager,committed_asset,manager_member,'Field preparation','2026-08-19T10:00:00Z','2026-08-19T12:00:00Z','[{"kind":"work_order"}]','gt10f-reservation-request','00000000-0000-4000-8000-000000001409','2026-08-19T08:08:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,reservation_id,'gt10f-reservation-confirm','00000000-0000-4000-8000-000000001410','2026-08-19T08:09:00Z');
 PERFORM check_out_group_shared_asset(org,gid,manager,reservation_id,manager_member,'good','{"label":"Main shed"}','[{"kind":"handover"}]','gt10f-reservation-checkout','00000000-0000-4000-8000-000000001411','2026-08-19T10:00:00Z');
 BEGIN
  PERFORM report_group_shared_asset_loss(org,gid,manager,committed_asset,'misplaced','Tractor location cannot be confirmed','{"label":"Unknown"}','[{"kind":"custody_check"}]','gt10f-committed-loss','00000000-0000-4000-8000-000000001415','2026-08-19T10:01:00Z');
  RAISE EXCEPTION 'committed asset loss accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='committed asset loss accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_LOSS_ASSET_COMMITTED%' THEN RAISE; END IF; END;
 loss_id:=report_group_shared_asset_loss(org,gid,manager,asset_id,'theft','Pump missing after locked-storage inspection','{"label":"Last known pump shed"}','[{"kind":"incident_report","reference":"loss-01"}]','gt10f-loss-report','00000000-0000-4000-8000-000000001412','2026-08-19T08:11:00Z');
 replay_id:=report_group_shared_asset_loss(org,gid,manager,asset_id,'theft','Pump missing after locked-storage inspection','{"label":"Last known pump shed"}','[{"kind":"incident_report","reference":"loss-01"}]','gt10f-loss-report','00000000-0000-4000-8000-000000001412','2026-08-19T08:11:00Z');
 IF replay_id<>loss_id OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='lost' AND availability_state='unavailable') THEN RAISE EXCEPTION 'GT10F loss report or replay failed'; END IF;
 BEGIN
  PERFORM report_group_shared_asset_loss(org,gid,manager,asset_id,'other','Changed report','{"label":"Unknown"}','[{"kind":"incident_report"}]','gt10f-loss-report','00000000-0000-4000-8000-000000001413','2026-08-19T08:12:00Z');
  RAISE EXCEPTION 'loss idempotency conflict accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='loss idempotency conflict accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_LOSS_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM request_group_shared_asset_reservation(org,gid,manager,asset_id,manager_member,'Attempt lost asset booking','2026-08-20T10:00:00Z','2026-08-20T12:00:00Z','[{"kind":"work_order"}]','gt10f-lost-reservation','00000000-0000-4000-8000-000000001414','2026-08-19T08:13:00Z');
  RAISE EXCEPTION 'lost asset reservation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='lost asset reservation accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_ASSET_INVALID%' THEN RAISE; END IF; END;
 IF (SELECT count(*) FROM group_shared_asset_loss_events e WHERE e.asset_id=fixture.asset_id)<>1 THEN RAISE EXCEPTION 'GT10F loss evidence not exactly once'; END IF;
 BEGIN
  UPDATE group_shared_asset_loss_events SET details='{}' WHERE id=loss_id;
  RAISE EXCEPTION 'loss evidence mutation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='loss evidence mutation accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_ENGINE_REQUIRED%' THEN RAISE; END IF; END;
END $$;
SELECT 'group shared asset loss event schema tests passed' AS result;
ROLLBACK;
