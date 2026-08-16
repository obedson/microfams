BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; requester UUID; outsider UUID; gid UUID;
 owner_member UUID; manager_member UUID; requester_member UUID; asset_id UUID; custody_reservation UUID; pending_reservation UUID; loss_id UUID; replay_id UUID;
BEGIN
 SELECT pg_get_functiondef('report_checked_out_group_shared_asset_loss(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_ASSET_CUSTODY_LOSS_PENDING_RESERVATIONS%' OR d NOT LIKE '%ASSET_LOSS_REPORTED%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10H custody-loss invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='group_shared_asset_reservations'::regclass AND pg_get_constraintdef(oid) LIKE '%loss_event_id%') THEN RAISE EXCEPTION 'GT10H loss consistency constraint missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10H tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10h-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10H Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10h-requester-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10H Requester','farmer') RETURNING id INTO requester;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,requester,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10h-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10H Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10H Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,requester,'member','active',TRUE,'paid',1000) RETURNING id INTO requester_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10H Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001601','2026-08-21T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001602','2026-08-21T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001603','2026-08-21T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001604','2026-08-21T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001605','2026-08-21T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_10h','GT10H Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10h-asset-register','00000000-0000-4000-8000-000000001606','2026-08-21T08:05:00Z');
 custody_reservation:=request_group_shared_asset_reservation(org,gid,requester,asset_id,requester_member,'Morning field work','2026-08-22T10:00:00Z','2026-08-22T12:00:00Z','[{"kind":"work_order"}]','gt10h-custody-request','00000000-0000-4000-8000-000000001607','2026-08-21T08:06:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,custody_reservation,'gt10h-custody-confirm','00000000-0000-4000-8000-000000001608','2026-08-21T08:07:00Z');
 PERFORM check_out_group_shared_asset(org,gid,manager,custody_reservation,requester_member,'good','{"label":"North field"}','[{"kind":"handover"}]','gt10h-custody-checkout','00000000-0000-4000-8000-000000001609','2026-08-22T10:00:00Z');
 pending_reservation:=request_group_shared_asset_reservation(org,gid,requester,asset_id,requester_member,'Afternoon field work','2026-08-22T13:00:00Z','2026-08-22T14:00:00Z','[{"kind":"work_order"}]','gt10h-pending-request','00000000-0000-4000-8000-000000001610','2026-08-22T10:01:00Z');
 BEGIN
  PERFORM report_checked_out_group_shared_asset_loss(org,gid,outsider,custody_reservation,'theft','Tractor missing from field','{"label":"North field"}','[{"kind":"incident_photo"}]','gt10h-denied-loss','00000000-0000-4000-8000-000000001611','2026-08-22T10:02:00Z');
  RAISE EXCEPTION 'unauthorized custody loss accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized custody loss accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM report_checked_out_group_shared_asset_loss(org,gid,manager,custody_reservation,'theft','Tractor missing from field','{"label":"North field"}','[{"kind":"incident_photo"}]','gt10h-pending-loss','00000000-0000-4000-8000-000000001612','2026-08-22T10:03:00Z');
  RAISE EXCEPTION 'custody loss with pending reservation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='custody loss with pending reservation accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_CUSTODY_LOSS_PENDING_RESERVATIONS%' THEN RAISE; END IF; END;
 PERFORM cancel_group_shared_asset_reservation(org,gid,requester,pending_reservation,'Asset custody incident under review','{"reference":"incident-01"}','gt10h-pending-cancel','00000000-0000-4000-8000-000000001613','2026-08-22T10:04:00Z');
 loss_id:=report_checked_out_group_shared_asset_loss(org,gid,manager,custody_reservation,'theft','Tractor missing after custody-holder field inspection','{"label":"Last known north field"}','[{"kind":"incident_report","reference":"loss-02"}]','gt10h-custody-loss','00000000-0000-4000-8000-000000001614','2026-08-22T10:05:00Z');
 replay_id:=report_checked_out_group_shared_asset_loss(org,gid,manager,custody_reservation,'theft','Tractor missing after custody-holder field inspection','{"label":"Last known north field"}','[{"kind":"incident_report","reference":"loss-02"}]','gt10h-custody-loss','00000000-0000-4000-8000-000000001614','2026-08-22T10:05:00Z');
 IF replay_id<>loss_id THEN RAISE EXCEPTION 'GT10H custody loss replay failed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND lifecycle_state='lost' AND availability_state='unavailable')
  OR NOT EXISTS(SELECT 1 FROM group_shared_asset_reservations WHERE id=custody_reservation AND state='lost' AND loss_event_id=loss_id AND lost_by=manager)
 THEN RAISE EXCEPTION 'GT10H atomic loss state missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_loss_events WHERE id=loss_id AND details->>'reservation_id'=custody_reservation::TEXT)
  OR NOT EXISTS(SELECT 1 FROM group_shared_asset_reservation_events WHERE reservation_id=custody_reservation AND event_type='ASSET_LOSS_REPORTED' AND evidence->>'loss_event_id'=loss_id::TEXT)
 THEN RAISE EXCEPTION 'GT10H linked loss evidence missing'; END IF;
 BEGIN
  PERFORM report_checked_out_group_shared_asset_loss(org,gid,manager,custody_reservation,'other','Changed report','{"label":"Unknown"}','[{"kind":"incident_report"}]','gt10h-custody-loss','00000000-0000-4000-8000-000000001615','2026-08-22T10:06:00Z');
  RAISE EXCEPTION 'custody loss idempotency conflict accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='custody loss idempotency conflict accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_CUSTODY_LOSS_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM check_in_group_shared_asset(org,gid,manager,custody_reservation,'good','{"label":"Main shed"}','[{"kind":"return"}]','gt10h-lost-checkin','00000000-0000-4000-8000-000000001616','2026-08-22T10:07:00Z');
  RAISE EXCEPTION 'lost custody checked in';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='lost custody checked in' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_STATE_INVALID%' THEN RAISE; END IF; END;
END $$;
SELECT 'group shared asset custody loss schema tests passed' AS result;
ROLLBACK;
