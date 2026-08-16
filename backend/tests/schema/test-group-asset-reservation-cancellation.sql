BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; requester UUID; outsider UUID; gid UUID;
 owner_member UUID; manager_member UUID; requester_member UUID; asset_one UUID; asset_two UUID;
 requested_reservation UUID; first_confirmed UUID; second_confirmed UUID; checkout_reservation UUID; replay_id UUID;
BEGIN
 SELECT pg_get_functiondef('cancel_group_shared_asset_reservation(uuid,uuid,uuid,uuid,text,jsonb,text,uuid,timestamp with time zone)'::regprocedure) INTO d;
 IF d NOT LIKE '%RESERVATION_CANCELLED%' OR d NOT LIKE '%pg_advisory_xact_lock%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10G cancellation invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='group_shared_asset_reservation_events'::regclass AND pg_get_constraintdef(oid) LIKE '%RESERVATION_CANCELLED%') THEN RAISE EXCEPTION 'GT10G cancellation event constraint missing'; END IF;
 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10G tenant fixture unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10g-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10G Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10g-requester-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10G Requester','farmer') RETURNING id INTO requester;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,requester,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10g-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10G Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10G Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,requester,'member','active',TRUE,'paid',1000) RETURNING id INTO requester_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10G Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001501','2026-08-20T08:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001502','2026-08-20T08:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001503','2026-08-20T08:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001504','2026-08-20T08:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001505','2026-08-20T08:04:00Z');
 asset_one:=register_group_shared_asset(org,gid,manager,'pump_10g','GT10G Pump','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Pump shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10g-asset-one','00000000-0000-4000-8000-000000001506','2026-08-20T08:05:00Z');
 asset_two:=register_group_shared_asset(org,gid,manager,'tractor_10g','GT10G Tractor','farm_equipment','{"type":"purchase"}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10g-asset-two','00000000-0000-4000-8000-000000001507','2026-08-20T08:06:00Z');
 requested_reservation:=request_group_shared_asset_reservation(org,gid,requester,asset_one,requester_member,'Irrigation','2026-08-21T10:00:00Z','2026-08-21T11:00:00Z','[{"kind":"work_order"}]','gt10g-self-request','00000000-0000-4000-8000-000000001508','2026-08-20T08:07:00Z');
 PERFORM cancel_group_shared_asset_reservation(org,gid,requester,requested_reservation,'Work rescheduled','{"reference":"requester-note-01"}','gt10g-self-cancel','00000000-0000-4000-8000-000000001509','2026-08-20T08:08:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_shared_asset_reservations WHERE id=requested_reservation AND state='cancelled') THEN RAISE EXCEPTION 'GT10G requester cancellation failed'; END IF;
 first_confirmed:=request_group_shared_asset_reservation(org,gid,requester,asset_two,requester_member,'Morning field work','2026-08-21T10:00:00Z','2026-08-21T11:00:00Z','[{"kind":"work_order"}]','gt10g-first-request','00000000-0000-4000-8000-000000001510','2026-08-20T08:09:00Z');
 second_confirmed:=request_group_shared_asset_reservation(org,gid,requester,asset_two,requester_member,'Afternoon field work','2026-08-21T12:00:00Z','2026-08-21T13:00:00Z','[{"kind":"work_order"}]','gt10g-second-request','00000000-0000-4000-8000-000000001511','2026-08-20T08:10:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,first_confirmed,'gt10g-first-confirm','00000000-0000-4000-8000-000000001512','2026-08-20T08:11:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,second_confirmed,'gt10g-second-confirm','00000000-0000-4000-8000-000000001513','2026-08-20T08:12:00Z');
 BEGIN
  PERFORM cancel_group_shared_asset_reservation(org,gid,outsider,first_confirmed,'Unauthorized cancellation','{}','gt10g-denied-cancel','00000000-0000-4000-8000-000000001514','2026-08-20T08:13:00Z');
  RAISE EXCEPTION 'unauthorized cancellation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='unauthorized cancellation accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_CANCEL_PERMISSION_DENIED%' THEN RAISE; END IF; END;
 replay_id:=cancel_group_shared_asset_reservation(org,gid,manager,first_confirmed,'Morning booking withdrawn','{"reference":"manager-note-01"}','gt10g-first-cancel','00000000-0000-4000-8000-000000001515','2026-08-20T08:14:00Z');
 IF replay_id<>first_confirmed OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_two AND availability_state='reserved') THEN RAISE EXCEPTION 'GT10G remaining reservation availability failed'; END IF;
 IF cancel_group_shared_asset_reservation(org,gid,manager,first_confirmed,'Morning booking withdrawn','{"reference":"manager-note-01"}','gt10g-first-cancel','00000000-0000-4000-8000-000000001515','2026-08-20T08:14:00Z')<>first_confirmed THEN RAISE EXCEPTION 'GT10G cancellation replay failed'; END IF;
 BEGIN
  PERFORM cancel_group_shared_asset_reservation(org,gid,manager,first_confirmed,'Changed reason','{}','gt10g-first-cancel','00000000-0000-4000-8000-000000001516','2026-08-20T08:15:00Z');
  RAISE EXCEPTION 'cancellation idempotency conflict accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='cancellation idempotency conflict accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_CANCEL_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF; END;
 PERFORM cancel_group_shared_asset_reservation(org,gid,manager,second_confirmed,'Afternoon booking withdrawn','{"reference":"manager-note-02"}','gt10g-second-cancel','00000000-0000-4000-8000-000000001517','2026-08-20T08:16:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_two AND availability_state='available') THEN RAISE EXCEPTION 'GT10G final cancellation availability failed'; END IF;
 checkout_reservation:=request_group_shared_asset_reservation(org,gid,requester,asset_two,requester_member,'Checked-out work','2026-08-21T14:00:00Z','2026-08-21T15:00:00Z','[{"kind":"work_order"}]','gt10g-checkout-request','00000000-0000-4000-8000-000000001518','2026-08-20T08:17:00Z');
 PERFORM confirm_group_shared_asset_reservation(org,gid,manager,checkout_reservation,'gt10g-checkout-confirm','00000000-0000-4000-8000-000000001519','2026-08-20T08:18:00Z');
 PERFORM check_out_group_shared_asset(org,gid,manager,checkout_reservation,requester_member,'good','{"label":"North field"}','[{"kind":"handover"}]','gt10g-checkout','00000000-0000-4000-8000-000000001520','2026-08-21T14:00:00Z');
 BEGIN
  PERFORM cancel_group_shared_asset_reservation(org,gid,manager,checkout_reservation,'Cannot cancel custody','{}','gt10g-checked-out-cancel','00000000-0000-4000-8000-000000001521','2026-08-21T14:01:00Z');
  RAISE EXCEPTION 'checked-out cancellation accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='checked-out cancellation accepted' OR SQLERRM NOT LIKE '%GROUP_ASSET_RESERVATION_CANCEL_STATE_INVALID%' THEN RAISE; END IF; END;
 IF (SELECT count(*) FROM group_shared_asset_reservation_events WHERE event_type='RESERVATION_CANCELLED' AND reservation_id IN(requested_reservation,first_confirmed,second_confirmed))<>3 THEN RAISE EXCEPTION 'GT10G cancellation evidence count invalid'; END IF;
END $$;
SELECT 'group shared asset reservation cancellation schema tests passed' AS result;
ROLLBACK;
