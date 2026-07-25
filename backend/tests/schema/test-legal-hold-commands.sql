BEGIN;
DO $$
DECLARE a UUID:='72000000-0000-4000-8000-000000000001'; u UUID:='72000000-0000-4000-8000-000000000002'; o UUID:='72000000-0000-4000-8000-000000000003'; other UUID:='72000000-0000-4000-8000-000000000004'; m UUID; h UUID; result JSONB; failed BOOLEAN;
BEGIN
 INSERT INTO users(id,email,password,name,role) VALUES(a,'hold-admin@test.local','hash','Admin','farmer'),(u,'hold-user@test.local','hash','User','farmer');
 INSERT INTO platform_administrator_assignments(user_id,grant_reason_code) VALUES(a,'TEST_BOOTSTRAP');
 INSERT INTO organizations(id,name,slug,type,created_by) VALUES(o,'Hold Org','hold-org','cooperative',a),(other,'Other Hold Org','other-hold-org','cooperative',a);
 INSERT INTO organization_memberships(organization_id,user_id,role,status,joined_at) VALUES(o,u,'member','active',NOW()) RETURNING id INTO m;
 result:=place_data_legal_hold(a,o,'membership',m::TEXT,'LITIGATION_NOTICE','Preserve membership evidence.','hold-place-001',repeat('1',64)); h:=(result->>'holdId')::UUID;
 IF h IS NULL OR result->>'status'<>'active' THEN RAISE EXCEPTION 'hold not placed'; END IF;
 IF place_data_legal_hold(a,o,'membership',m::TEXT,'LITIGATION_NOTICE','Preserve membership evidence.','hold-place-001',repeat('1',64))->>'holdId'<>h::TEXT THEN RAISE EXCEPTION 'placement not idempotent'; END IF;
 failed:=FALSE; BEGIN PERFORM place_data_legal_hold(a,other,'membership',m::TEXT,'LITIGATION_NOTICE',NULL,'hold-place-002',repeat('2',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'cross-organization hold allowed'; END IF;
 failed:=FALSE; BEGIN UPDATE data_legal_holds SET reason_code='TAMPERED' WHERE id=h; EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'hold evidence mutable'; END IF;
 result:=release_data_legal_hold(a,h,'MATTER_CLOSED','Release approved.','hold-release01',repeat('3',64));
 IF result->>'status'<>'released' THEN RAISE EXCEPTION 'hold not released'; END IF;
 IF release_data_legal_hold(a,h,'MATTER_CLOSED','Release approved.','hold-release01',repeat('3',64))->>'status'<>'released' THEN RAISE EXCEPTION 'release not idempotent'; END IF;
 failed:=FALSE; BEGIN DELETE FROM data_legal_hold_events WHERE hold_id=h; EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'hold events mutable'; END IF;
 IF has_table_privilege('authenticated','data_legal_holds','SELECT') OR has_table_privilege('authenticated','data_legal_hold_events','SELECT') THEN RAISE EXCEPTION 'authenticated role can read legal holds'; END IF;
END; $$;
ROLLBACK;
SELECT 'legal hold command schema tests passed' AS result;