BEGIN;
DO $$
DECLARE a UUID:='71000000-0000-4000-8000-000000000001'; r UUID:='71000000-0000-4000-8000-000000000002'; u UUID:='71000000-0000-4000-8000-000000000003'; c UUID; result JSONB; failed BOOLEAN:=FALSE;
BEGIN
 INSERT INTO users(id,email,password,name,role) VALUES(a,'rec-admin@test.local','hash','Admin','farmer'),(r,'rec-reviewer@test.local','hash','Reviewer','farmer'),(u,'rec-user@test.local','hash','User','farmer');
 INSERT INTO platform_administrator_assignments(user_id,grant_reason_code) VALUES(a,'TEST_BOOTSTRAP'),(r,'TEST_BOOTSTRAP');
 result:=open_trust_review_case(a,NULL,'user',u,'ACCOUNT_RISK','high','recovery-open-01',repeat('1',64)); c:=(result->>'caseId')::UUID;
 PERFORM assign_trust_review_case(a,c,r,'recovery-assign1',repeat('2',64));
 PERFORM decide_trust_review_case(r,c,'suspend_user','ACCOUNT_RISK','Evidence supports temporary account suspension.','recovery-decide1',repeat('3',64));
 PERFORM suspend_platform_user(a,u,'ACCOUNT_RISK','Decision-backed test');
 result:=issue_suspended_account_recovery(u,c,repeat('a',64),'email',NOW()+INTERVAL '15 minutes');
 IF result->>'tokenId' IS NULL OR inspect_suspended_account_recovery(repeat('a',64))->>'caseId'<>c::TEXT THEN RAISE EXCEPTION 'token unavailable'; END IF;
 result:=file_suspended_account_recovery_appeal(repeat('a',64),'The decision omitted material evidence.','recovery-appeal1',repeat('4',64));
 IF result->>'status'<>'filed' THEN RAISE EXCEPTION 'appeal not filed'; END IF;
 IF file_suspended_account_recovery_appeal(repeat('a',64),'The decision omitted material evidence.','recovery-appeal1',repeat('4',64))->>'appealId'<>result->>'appealId' THEN RAISE EXCEPTION 'retry not idempotent'; END IF;
 BEGIN PERFORM inspect_suspended_account_recovery(repeat('a',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'consumed token remained usable'; END IF;
 IF has_table_privilege('authenticated','suspended_account_recovery_tokens','SELECT') THEN RAISE EXCEPTION 'authenticated can read tokens'; END IF;
END; $$;
ROLLBACK;
SELECT 'suspended recovery schema tests passed' AS result;