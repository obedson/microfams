BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; manager UUID; outsider UUID; gid UUID; owner_member UUID; manager_member UUID; asset_id UUID; replay_id UUID;
BEGIN
 IF to_regclass('public.group_shared_assets') IS NULL OR to_regclass('public.group_shared_asset_events') IS NULL THEN RAISE EXCEPTION 'GT10C shared asset tables missing'; END IF;
 SELECT pg_get_functiondef('group_shared_asset_actor_permitted(UUID,UUID)'::regprocedure) INTO d;
 IF d NOT LIKE '%groups.assets.manage%' THEN RAISE EXCEPTION 'GT10C asset permission invariant missing'; END IF;
 SELECT pg_get_functiondef('register_group_shared_asset(UUID,UUID,UUID,TEXT,TEXT,TEXT,JSONB,UUID,JSONB,TEXT,JSONB,JSONB,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%pg_advisory_xact_lock%' OR d NOT LIKE '%GROUP_SHARED_ASSET_ACTIVE_GROUP_REQUIRED%' OR d NOT LIKE '%GROUP_SHARED_ASSET_CUSTODIAN_INVALID%' OR d LIKE '%post_financial_journal%' THEN RAISE EXCEPTION 'GT10C registration invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='group_shared_assets' AND policyname='tenant_read') THEN RAISE EXCEPTION 'GT10C tenant policy missing'; END IF;

 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10C tenant fixture is unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10c-manager-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10C Asset Manager','farmer') RETURNING id INTO manager;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,manager,'member','active',ARRAY['groups.assets.manage'],NOW());
 INSERT INTO users(email,password,name,role) VALUES('gt10c-outsider-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10C Outsider','farmer') RETURNING id INTO outsider;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,outsider,'member','active',ARRAY['groups.read'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10C Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,manager,'member','active',TRUE,'paid',1000) RETURNING id INTO manager_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10C Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001101','2026-08-15T12:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001102','2026-08-15T12:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001103','2026-08-15T12:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001104','2026-08-15T12:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001105','2026-08-15T12:04:00Z');

 BEGIN
  PERFORM register_group_shared_asset(org,gid,outsider,'tractor_01','Cooperative Tractor','farm_equipment','{"type":"purchase","reference":"invoice-001"}',manager_member,'{"label":"Main shed"}','good','{"currency":"NGN","amount_minor":"25000000"}','{"method":"straight_line","useful_life_months":60}','{"interval_days":90}','[{"kind":"invoice","reference":"invoice-001"}]','gt10c-denied','00000000-0000-4000-8000-000000001106','2026-08-15T12:05:00Z');
  RAISE EXCEPTION 'asset registration was granted without permission';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='asset registration was granted without permission' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_PERMISSION_DENIED%' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM register_group_shared_asset(org,gid,manager,'tractor_01','Cooperative Tractor','farm_equipment','{"type":"purchase"}',gen_random_uuid(),'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10c-bad-custodian','00000000-0000-4000-8000-000000001107','2026-08-15T12:06:00Z');
  RAISE EXCEPTION 'asset registration accepted an invalid custodian';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='asset registration accepted an invalid custodian' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_CUSTODIAN_INVALID%' THEN RAISE; END IF;
 END;

 BEGIN
  PERFORM register_group_shared_asset(org,gid,manager,'tractor_01','Cooperative Tractor','farm_equipment','{}',manager_member,'{"label":"Main shed"}','good','{}','{}','{}','[{"kind":"invoice"}]','gt10c-bad-source','00000000-0000-4000-8000-000000001108','2026-08-15T12:06:30Z');
  RAISE EXCEPTION 'asset registration accepted an unclassified source';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='asset registration accepted an unclassified source' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_COMMAND_INVALID%' THEN RAISE; END IF;
 END;

 asset_id:=register_group_shared_asset(org,gid,manager,'tractor_01','Cooperative Tractor','farm_equipment','{"type":"purchase","reference":"invoice-001"}',manager_member,'{"label":"Main shed","state":"Kaduna"}','good','{"currency":"NGN","amount_minor":"25000000"}','{"method":"straight_line","useful_life_months":60}','{"interval_days":90,"next_due_on":"2026-11-15"}','[{"kind":"invoice","reference":"invoice-001"}]','gt10c-tractor-register','00000000-0000-4000-8000-000000001108','2026-08-15T12:07:00Z');
 BEGIN
  PERFORM register_group_shared_asset(org,gid,manager,'tractor_01','Changed Tractor Name','farm_equipment','{"type":"purchase","reference":"invoice-001"}',manager_member,'{"label":"Main shed","state":"Kaduna"}','good','{"currency":"NGN","amount_minor":"25000000"}','{"method":"straight_line","useful_life_months":60}','{"interval_days":90,"next_due_on":"2026-11-15"}','[{"kind":"invoice","reference":"invoice-001"}]','gt10c-tractor-register','00000000-0000-4000-8000-000000001109','2026-08-15T12:08:00Z');
  RAISE EXCEPTION 'changed asset payload reused an idempotency key';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='changed asset payload reused an idempotency key' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_IDEMPOTENCY_CONFLICT%' THEN RAISE; END IF;
 END;
 replay_id:=register_group_shared_asset(org,gid,manager,'tractor_01','Cooperative Tractor','farm_equipment','{"type":"purchase","reference":"invoice-001"}',manager_member,'{"label":"Main shed","state":"Kaduna"}','good','{"currency":"NGN","amount_minor":"25000000"}','{"method":"straight_line","useful_life_months":60}','{"interval_days":90,"next_due_on":"2026-11-15"}','[{"kind":"invoice","reference":"invoice-001"}]','gt10c-tractor-register','00000000-0000-4000-8000-000000001110','2026-08-15T12:09:00Z');
 IF replay_id<>asset_id THEN RAISE EXCEPTION 'GT10C idempotent replay changed the asset'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset_id AND organization_id=org AND group_id=gid AND custodian_member_id=manager_member AND lifecycle_state='active' AND availability_state='available') THEN RAISE EXCEPTION 'GT10C asset registry facts were not recorded'; END IF;
 IF (SELECT count(*) FROM group_shared_asset_events WHERE group_shared_asset_events.asset_id=fixture.asset_id AND event_type='ASSET_REGISTERED')<>1 THEN RAISE EXCEPTION 'GT10C acquisition evidence was not exactly once'; END IF;
 BEGIN
  UPDATE group_shared_assets SET valuation_metadata='{"amount_minor":"1"}' WHERE id=asset_id;
  RAISE EXCEPTION 'shared asset evidence was mutated directly';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='shared asset evidence was mutated directly' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_SHARED_ASSET_ENGINE_REQUIRED%' THEN RAISE; END IF;
 END;
END $$;
SELECT 'group shared asset schema tests passed' AS result;
ROLLBACK;
