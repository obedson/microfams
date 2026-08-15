BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; requester_user UUID; outsider UUID; gid UUID;
 owner_member UUID; manager_member UUID; requester_member UUID; asset_id UUID; damage_id UUID; replay_id UUID; maintenance_id UUID; reservation_id UUID;
BEGIN
 IF to_regclass('public.group_shared_asset_condition_events') IS NULL THEN RAISE EXCEPTION 'GT10E condition event table missing'; END IF;
 SELECT pg_get_functiondef('start_group_shared_asset_maintenance(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%pg_advisory_xact_lock%' OR d NOT LIKE '%group_shared_asset_reservations%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10E maintenance invariant missing'; END IF;
 SELECT pg_get_functiondef('report_group_shared_asset_damage(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_ASSET_CONDITION_ASSET_COMMITTED%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10E damage invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='group_shared_asset_condition_events' AND policyname='tenant_read') THEN RAISE EXCEPTION 'GT10E tenant policy missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10E tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10e-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10E Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10e-requester-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10E Requester','farmer') RETURNING id INTO requester_user;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,requester_user,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10e-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10E Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10E Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,requester_user,'member','active',TRUE,'paid',1000) RETURNING id INTO requester_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10E Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001301','2026-08-18T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001302','2026-08-18T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001303','2026-08-18T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001304','2026-08-18T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001305','2026-08-18T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_10e','GT10E Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{"interval_days":90}','[{"kind":"invoice"}]','gt10e-asset-register','00000000-0000-4000-8000-000000001306','2026-08-18T08:05:00Z');
 BEGIN
  PERFORM report_group_shared_asset_damage(org,gid,outsider,asset_id,'major','Hydraulic leak','{"label":"Main shed"}','[{"kind":"photo"}]','gt10e-denied-damage','00000000-0000-4000-8000-000000001307','2026-08-18T08:06:00Z');
  RAISE EXCEPTION 'unauthorized damage report accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized damage report accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 damage_id:=report_group_shared_asset_damage(org,gid,manager,asset_id,'major','Hydraulic leak','{"label":"Main shed"}','[{"kind":"photo","reference":"damage-01"}]','gt10e-damage-report','00000000-0000-4000-8000-000000001308','2026-08-18T08:07:00Z');
 replay_id:=report_group_shared_asset_damage(org,gid,manager,asset_id,'major','Hydraulic leak','{"label":"Main shed"}','[{"kind":"photo","reference":"damage-01"}]','gt10e-damage-report','00000000-0000-4000-8000-000000001308','2026-08-18T08:07:00Z');
 IF replay_id<>damage_id OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND condition_state='damaged' AND availability_state='unavailable') THEN RAISE EXCEPTION 'GT10E damage report or replay failed'; END IF;
 BEGIN
  PERFORM report_group_shared_asset_damage(org,gid,manager,asset_id,'minor','Changed report','{"label":"Main shed"}','[{"kind":"photo","reference":"damage-01"}]','gt10e-damage-report','00000000-0000-4000-8000-000000001309','2026-08-18T08:08:00Z');
  RAISE EXCEPTION 'damage idempotency conflict accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='damage idempotency conflict accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_CONDITION_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 maintenance_id:=start_group_shared_asset_maintenance(org,gid,manager,asset_id,'Replace hydraulic hose','{"name":"Approved Workshop","reference":"vendor-01"}','{"label":"Approved Workshop"}','[{"kind":"work_order","reference":"maint-01"}]','gt10e-maint-start','00000000-0000-4000-8000-000000001310','2026-08-18T09:00:00Z');
 replay_id:=start_group_shared_asset_maintenance(org,gid,manager,asset_id,'Replace hydraulic hose','{"name":"Approved Workshop","reference":"vendor-01"}','{"label":"Approved Workshop"}','[{"kind":"work_order","reference":"maint-01"}]','gt10e-maint-start','00000000-0000-4000-8000-000000001310','2026-08-18T09:00:00Z');
 IF replay_id<>maintenance_id OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND availability_state='maintenance') THEN RAISE EXCEPTION 'GT10E maintenance start or replay failed'; END IF;
 reservation_id:=request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Field preparation','2026-08-19T12:00:00Z','2026-08-19T14:00:00Z','[{"kind":"work_order"}]','gt10e-reservation-request','00000000-0000-4000-8000-000000001311','2026-08-18T09:05:00Z');
 BEGIN
  PERFORM confirm_group_shared_asset_reservation(org,gid,manager,reservation_id,'gt10e-reservation-confirm','00000000-0000-4000-8000-000000001312','2026-08-18T09:06:00Z');
  RAISE EXCEPTION 'maintenance asset reservation confirmed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='maintenance asset reservation confirmed' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_ASSET_UNAVAILABLE%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM complete_group_shared_asset_maintenance(org,gid,manager,asset_id,maintenance_id,'good','Hose replaced and pressure tested','{"label":"Main shed"}','2026-08-18T09:00:00Z','[{"kind":"service_report"}]','gt10e-bad-complete','00000000-0000-4000-8000-000000001313','2026-08-18T10:00:00Z');
  RAISE EXCEPTION 'invalid next maintenance date accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='invalid next maintenance date accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_CONDITION_COMMAND_INVALID%' THEN RAISE; END IF; END;
 PERFORM complete_group_shared_asset_maintenance(org,gid,manager,asset_id,maintenance_id,'good','Hose replaced and pressure tested','{"label":"Main shed"}','2026-11-18T10:00:00Z','[{"kind":"service_report","reference":"maint-01"}]','gt10e-maint-complete','00000000-0000-4000-8000-000000001314','2026-08-18T10:00:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND condition_state='good' AND availability_state='available' AND maintenance_schedule->>'next_due_at' IS NOT NULL) THEN RAISE EXCEPTION 'GT10E maintenance completion state missing'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_condition_events e WHERE e.asset_id=fixture.asset_id AND e.event_type='DAMAGE_REPORTED')<>1 OR (SELECT count(*) FROM group_shared_asset_condition_events e WHERE e.related_event_id=maintenance_id AND e.event_type='MAINTENANCE_COMPLETED')<>1 THEN RAISE EXCEPTION 'GT10E event evidence not exactly once'; END IF;
 BEGIN
  UPDATE group_shared_asset_condition_events SET details='{}' WHERE id=damage_id;
  RAISE EXCEPTION 'condition evidence mutation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='condition evidence mutation accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_ENGINE_REQUIRED%' THEN RAISE; END IF; END;
END $$;
SELECT 'group shared asset condition event schema tests passed' AS result;
ROLLBACK;
