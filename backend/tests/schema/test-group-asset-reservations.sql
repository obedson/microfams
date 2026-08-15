BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; requester_user UUID; outsider UUID; gid UUID; owner_member UUID; manager_member UUID; requester_member UUID; asset_id UUID; first_id UUID; replay_id UUID; overlap_id UUID; adjacent_id UUID;
BEGIN
 IF to_regclass('public.group_shared_asset_reservations') IS NULL OR to_regclass('public.group_shared_asset_reservation_events') IS NULL THEN RAISE EXCEPTION 'GT10D tables missing'; END IF;
 SELECT pg_get_functiondef('confirm_group_shared_asset_reservation(uuid,uuid,uuid,uuid,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%pg_advisory_xact_lock%' OR d NOT LIKE '%tstzrange%' OR d NOT LIKE '%GROUP_ASSET_RESERVATION_OVERLAP%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10D reservation invariant missing'; END IF;
 SELECT pg_get_functiondef('check_in_group_shared_asset(uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%availability_state%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10D custody invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='group_shared_asset_reservations' AND policyname='tenant_read') THEN RAISE EXCEPTION 'GT10D tenant policy missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10D tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10d-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10D Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10d-requester-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10D Requester','farmer') RETURNING id INTO requester_user;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,requester_user,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10d-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10D Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10D Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,requester_user,'member','active',TRUE,'paid',1000) RETURNING id INTO requester_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10D Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001201','2026-08-16T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001202','2026-08-16T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001203','2026-08-16T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001204','2026-08-16T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001205','2026-08-16T08:04:00Z');
 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_10d','GT10D Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10d-asset-register','00000000-0000-4000-8000-000000001206','2026-08-16T08:05:00Z');
 BEGIN
  PERFORM request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Bad window','2026-08-17T14:00:00Z','2026-08-17T12:00:00Z','[{"kind":"request"}]','gt10d-bad-window','00000000-0000-4000-8000-000000001207','2026-08-16T08:06:00Z');
  RAISE EXCEPTION 'invalid window accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='invalid window accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_COMMAND_INVALID%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM request_group_shared_asset_reservation(org,gid,outsider,asset_id,requester_member,'Mismatched member','2026-08-17T12:00:00Z','2026-08-17T14:00:00Z','[{"kind":"request"}]','gt10d-bad-member','00000000-0000-4000-8000-000000001208','2026-08-16T08:07:00Z');
  RAISE EXCEPTION 'mismatched member accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='mismatched member accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_MEMBER_INVALID%' THEN RAISE; END IF; END;
 first_id:=request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Prepare cooperative field','2026-08-17T12:00:00Z','2026-08-17T14:00:00Z','[{"kind":"work_order","reference":"field-01"}]','gt10d-first-request','00000000-0000-4000-8000-000000001209','2026-08-16T08:08:00Z');
 replay_id:=request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Prepare cooperative field','2026-08-17T12:00:00Z','2026-08-17T14:00:00Z','[{"kind":"work_order","reference":"field-01"}]','gt10d-first-request','00000000-0000-4000-8000-000000001209','2026-08-16T08:08:00Z');
 IF replay_id<>first_id THEN RAISE EXCEPTION 'GT10D request replay changed reservation'; END IF;
 BEGIN
  PERFORM request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Changed purpose','2026-08-17T12:00:00Z','2026-08-17T14:00:00Z','[{"kind":"work_order","reference":"field-01"}]','gt10d-first-request','00000000-0000-4000-8000-000000001210','2026-08-16T08:09:00Z');
  RAISE EXCEPTION 'idempotency conflict accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='idempotency conflict accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM confirm_group_shared_asset_reservation(org,gid,outsider,first_id,'gt10d-denied-confirm','00000000-0000-4000-8000-000000001211','2026-08-16T08:10:00Z');
  RAISE EXCEPTION 'unauthorized confirmation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized confirmation accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,first_id,'gt10d-first-confirm','00000000-0000-4000-8000-000000001212','2026-08-16T08:11:00Z');
 overlap_id:=request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Overlapping work','2026-08-17T13:00:00Z','2026-08-17T15:00:00Z','[{"kind":"work_order"}]','gt10d-overlap-request','00000000-0000-4000-8000-000000001213','2026-08-16T08:12:00Z');
 BEGIN
  PERFORM confirm_group_shared_asset_reservation(org,gid,manager,overlap_id,'gt10d-overlap-confirm','00000000-0000-4000-8000-000000001214','2026-08-16T08:13:00Z');
  RAISE EXCEPTION 'overlap confirmed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='overlap confirmed' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_OVERLAP%' THEN RAISE; END IF; END;
 adjacent_id:=request_group_shared_asset_reservation(org,gid,requester_user,asset_id,requester_member,'Adjacent work','2026-08-17T14:00:00Z','2026-08-17T16:00:00Z','[{"kind":"work_order"}]','gt10d-adjacent-request','00000000-0000-4000-8000-000000001215','2026-08-16T08:14:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,adjacent_id,'gt10d-adjacent-confirm','00000000-0000-4000-8000-000000001216','2026-08-16T08:15:00Z');
 BEGIN
  PERFORM check_out_group_shared_asset(org,gid,manager,first_id,requester_member,'good','{"label":"Main shed"}','[{"kind":"handover"}]','gt10d-early-checkout','00000000-0000-4000-8000-000000001217','2026-08-17T11:59:00Z');
  RAISE EXCEPTION 'early checkout accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='early checkout accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_CHECKOUT_WINDOW_INVALID%' THEN RAISE; END IF; END;
 PERFORM check_out_group_shared_asset(org,gid,manager,first_id,requester_member,'good','{"label":"Main shed"}','[{"kind":"handover","reference":"checkout"}]','gt10d-first-checkout','00000000-0000-4000-8000-000000001218','2026-08-17T12:30:00Z');
 replay_id:=check_out_group_shared_asset(org,gid,manager,first_id,requester_member,'good','{"label":"Main shed"}','[{"kind":"handover","reference":"checkout"}]','gt10d-first-checkout','00000000-0000-4000-8000-000000001218','2026-08-17T12:30:00Z');
 IF replay_id<>first_id OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND availability_state='checked_out') THEN RAISE EXCEPTION 'GT10D checkout or replay failed'; END IF;
 BEGIN
  UPDATE group_shared_asset_reservations SET purpose='Direct mutation' WHERE id=first_id;
  RAISE EXCEPTION 'direct mutation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='direct mutation accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_ENGINE_REQUIRED%' THEN RAISE; END IF; END;
 PERFORM check_in_group_shared_asset(org,gid,manager,first_id,'fair','{"label":"North field shelter"}','[{"kind":"handover","reference":"checkin"}]','gt10d-first-checkin','00000000-0000-4000-8000-000000001219','2026-08-17T13:30:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_reservations WHERE id=first_id AND state='completed' AND checkout_recipient_member_id=requester_member AND checkout_condition='good' AND return_condition='fair') THEN RAISE EXCEPTION 'GT10D custody snapshots missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND availability_state='reserved' AND condition_state='fair' AND location='{"label":"North field shelter"}') THEN RAISE EXCEPTION 'GT10D check-in state invalid'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_reservation_events WHERE reservation_id=first_id AND event_type='ASSET_CHECKED_OUT')<>1 OR (SELECT count(*) FROM group_shared_asset_reservation_events WHERE reservation_id=first_id AND event_type='ASSET_CHECKED_IN')<>1 THEN RAISE EXCEPTION 'GT10D custody evidence not exactly once'; END IF;
 BEGIN
  UPDATE group_shared_asset_reservation_events SET evidence='{}' WHERE reservation_id=first_id;
  RAISE EXCEPTION 'event mutation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='event mutation accepted' OR SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_ENGINE_REQUIRED%' THEN RAISE; END IF; END;
END $$;
SELECT 'group shared asset reservation schema tests passed' AS result;
ROLLBACK;
