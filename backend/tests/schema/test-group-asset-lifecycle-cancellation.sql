BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; gid UUID; owner_member UUID; manager_member UUID;
 asset_id UUID; requested_id UUID; confirmed_id UUID; loss_id UUID; replay_id UUID;
BEGIN
 SELECT pg_get_functiondef('report_group_shared_asset_loss(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%cancellation_source%' OR d NOT LIKE '%loss_event_id%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10I lifecycle cancellation invariant missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10I tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10i-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10I Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10I Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10I Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001701','2026-08-22T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001702','2026-08-22T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001703','2026-08-22T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001704','2026-08-22T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001705','2026-08-22T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'pump_10i','GT10I Irrigation Pump','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Pump shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10i-asset-register','00000000-0000-4000-8000-000000001706','2026-08-22T08:05:00Z');
 requested_id:=request_group_shared_asset_reservation(org,gid,manager,asset_id,manager_member,'Morning irrigation','2026-08-23T10:00:00Z','2026-08-23T11:00:00Z','[{"kind":"work_order"}]','gt10i-requested-booking','00000000-0000-4000-8000-000000001707','2026-08-22T08:06:00Z');
 confirmed_id:=request_group_shared_asset_reservation(org,gid,manager,asset_id,manager_member,'Afternoon irrigation','2026-08-23T12:00:00Z','2026-08-23T13:00:00Z','[{"kind":"work_order"}]','gt10i-confirmed-booking','00000000-0000-4000-8000-000000001708','2026-08-22T08:07:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,confirmed_id,'gt10i-booking-confirm','00000000-0000-4000-8000-000000001709','2026-08-22T08:08:00Z');
 loss_id:=report_group_shared_asset_loss(org,gid,manager,asset_id,'theft','Pump missing after storage inspection','{"label":"Last known pump shed"}','[{"kind":"incident_report","reference":"loss-10i"}]','gt10i-loss-report','00000000-0000-4000-8000-000000001710','2026-08-22T08:09:00Z');
 replay_id:=report_group_shared_asset_loss(org,gid,manager,asset_id,'theft','Pump missing after storage inspection','{"label":"Last known pump shed"}','[{"kind":"incident_report","reference":"loss-10i"}]','gt10i-loss-report','00000000-0000-4000-8000-000000001710','2026-08-22T08:09:00Z');
 IF replay_id<>loss_id THEN RAISE EXCEPTION 'GT10I loss replay failed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='lost' AND availability_state='unavailable')
  OR (SELECT count(*) FROM group_shared_asset_reservations WHERE id IN(requested_id,confirmed_id) AND state='cancelled')<>2
 THEN RAISE EXCEPTION 'GT10I atomic lifecycle state missing'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_reservation_events WHERE reservation_id IN(requested_id,confirmed_id) AND event_type='RESERVATION_CANCELLED'
      AND evidence->>'cancellation_source'='asset_lifecycle' AND evidence->>'loss_event_id'=loss_id::TEXT)<>2
 THEN RAISE EXCEPTION 'GT10I linked cancellation evidence missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_loss_events WHERE id=loss_id AND details->>'cancelled_reservation_count'='2')
  OR (SELECT count(*) FROM group_shared_asset_reservation_events WHERE reservation_id IN(requested_id,confirmed_id) AND event_type='RESERVATION_CANCELLED')<>2
 THEN RAISE EXCEPTION 'GT10I cancellation replay was not exactly once'; END IF;
END $$;
SELECT 'group asset lifecycle cancellation schema tests passed' AS result;
ROLLBACK;
