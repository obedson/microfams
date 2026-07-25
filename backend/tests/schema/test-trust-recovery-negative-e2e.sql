-- End-to-end negative-path contract for trust review and suspended-account recovery.
BEGIN;
DO $$
DECLARE
 admin_id UUID:='74000000-0000-4000-8000-000000000001'; reviewer_id UUID:='74000000-0000-4000-8000-000000000002'; appeal_reviewer_id UUID:='74000000-0000-4000-8000-000000000003';
 user_id UUID:='74000000-0000-4000-8000-000000000004'; outsider_id UUID:='74000000-0000-4000-8000-000000000005';
 case_id UUID; self_case_id UUID; appeal_id UUID; suspension_id UUID; token_b UUID; result JSONB; failed BOOLEAN;
BEGIN
 INSERT INTO users(id,email,password,name,role) VALUES
  (admin_id,'negative-admin@test.local','hash','Admin','farmer'),
  (reviewer_id,'negative-reviewer@test.local','hash','Reviewer','farmer'),
  (appeal_reviewer_id,'negative-appeal-reviewer@test.local','hash','Appeal Reviewer','farmer'),
  (user_id,'negative-user@test.local','hash','User','farmer'),
  (outsider_id,'negative-outsider@test.local','hash','Outsider','farmer');
 INSERT INTO platform_administrator_assignments(user_id,grant_reason_code) VALUES
  (admin_id,'TEST_BOOTSTRAP'),(reviewer_id,'TEST_BOOTSTRAP'),(appeal_reviewer_id,'TEST_BOOTSTRAP');

 failed:=FALSE; BEGIN PERFORM open_trust_review_case(outsider_id,NULL,'user',user_id,'ACCOUNT_RISK','high','neg-open-denied1',repeat('1',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'non-administrator opened trust case'; END IF;

 result:=open_trust_review_case(admin_id,NULL,'user',user_id,'ACCOUNT_RISK','high','neg-open-main01',repeat('2',64)); case_id:=(result->>'caseId')::UUID;
 failed:=FALSE; BEGIN PERFORM open_trust_review_case(admin_id,NULL,'user',user_id,'ACCOUNT_RISK','high','neg-open-main01',repeat('3',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'idempotency key accepted different facts'; END IF;

 result:=open_trust_review_case(admin_id,NULL,'user',reviewer_id,'ACCOUNT_RISK','normal','neg-open-self01',repeat('4',64)); self_case_id:=(result->>'caseId')::UUID;
 failed:=FALSE; BEGIN PERFORM assign_trust_review_case(admin_id,self_case_id,reviewer_id,'neg-assign-self1',repeat('5',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'reviewer was assigned to their own case'; END IF;

 PERFORM assign_trust_review_case(admin_id,case_id,reviewer_id,'neg-assign-main1',repeat('6',64));
 failed:=FALSE; BEGIN PERFORM decide_trust_review_case(appeal_reviewer_id,case_id,'suspend_user','ACCOUNT_RISK','Unauthorized reviewer decision attempt.','neg-decide-wrong1',repeat('7',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'unassigned reviewer decided trust case'; END IF;
 PERFORM decide_trust_review_case(reviewer_id,case_id,'suspend_user','ACCOUNT_RISK','Evidence supports a temporary account suspension.','neg-decide-main1',repeat('8',64));

 failed:=FALSE; BEGIN PERFORM file_trust_appeal(outsider_id,case_id,'I am not the affected account owner.','neg-appeal-out01',repeat('9',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'unauthorized outsider filed trust appeal'; END IF;
 failed:=FALSE; BEGIN PERFORM suspend_trust_user(admin_id,outsider_id,case_id,'ACCOUNT_RISK','Wrong subject attempt.','neg-suspend-wr1',repeat('a',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'decision suspended a different user'; END IF;

 PERFORM suspend_trust_user(admin_id,user_id,case_id,'ACCOUNT_RISK','Decision-backed negative-path test.','neg-suspend-main',repeat('b',64));
 SELECT id INTO suspension_id FROM user_account_suspensions WHERE user_id=user_id AND status='active';
 failed:=FALSE; BEGIN PERFORM issue_suspended_account_recovery(user_id,self_case_id,repeat('c',64),'email',NOW()+INTERVAL '15 minutes'); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'recovery token issued for an unrelated case'; END IF;

 PERFORM issue_suspended_account_recovery(user_id,case_id,repeat('d',64),'email',NOW()+INTERVAL '15 minutes');
 result:=issue_suspended_account_recovery(user_id,case_id,repeat('e',64),'email',NOW()+INTERVAL '15 minutes'); token_b:=(result->>'tokenId')::UUID;
 failed:=FALSE; BEGIN PERFORM inspect_suspended_account_recovery(repeat('d',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'superseded recovery token remained usable'; END IF;
 PERFORM invalidate_suspended_account_recovery(token_b,'DELIVERY_FAILED');
 failed:=FALSE; BEGIN PERFORM inspect_suspended_account_recovery(repeat('e',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'invalidated recovery token remained usable'; END IF;

 INSERT INTO suspended_account_recovery_tokens(user_id,suspension_id,case_id,token_digest,delivery_channel,requested_at,expires_at)
 VALUES(user_id,suspension_id,case_id,repeat('f',64),'email',NOW()-INTERVAL '30 minutes',NOW()-INTERVAL '1 minute');
 failed:=FALSE; BEGIN PERFORM inspect_suspended_account_recovery(repeat('f',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'expired recovery token remained usable'; END IF;

 PERFORM issue_suspended_account_recovery(user_id,case_id,repeat('0',64),'email',NOW()+INTERVAL '15 minutes');
 result:=file_suspended_account_recovery_appeal(repeat('0',64),'Material evidence was omitted from the decision.','neg-recovery-app1',repeat('1',64)); appeal_id:=(result->>'appealId')::UUID;
 IF file_suspended_account_recovery_appeal(repeat('0',64),'Material evidence was omitted from the decision.','neg-recovery-app1',repeat('1',64))->>'appealId'<>appeal_id::TEXT THEN RAISE EXCEPTION 'safe appeal retry was not idempotent'; END IF;
 failed:=FALSE; BEGIN PERFORM file_suspended_account_recovery_appeal(repeat('0',64),'Different facts after token consumption.','neg-recovery-app2',repeat('2',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'consumed token accepted a different appeal'; END IF;
 failed:=FALSE; BEGIN PERFORM decide_trust_appeal(reviewer_id,appeal_id,'overturned','NEW_EVIDENCE','Original reviewer cannot decide the appeal.','neg-appeal-dec01',repeat('3',64)); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'original reviewer decided recovery appeal'; END IF;
 PERFORM decide_trust_appeal(appeal_reviewer_id,appeal_id,'overturned','NEW_EVIDENCE','Independent review found material evidence.','neg-appeal-dec02',repeat('4',64));
 PERFORM resume_platform_user(admin_id,user_id,'APPEAL_OVERTURNED');
 failed:=FALSE; BEGIN PERFORM issue_suspended_account_recovery(user_id,case_id,repeat('5',64),'email',NOW()+INTERVAL '15 minutes'); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'recovery token issued after account resumption'; END IF;

 failed:=FALSE; BEGIN DELETE FROM suspended_account_recovery_events WHERE user_id=user_id; EXCEPTION WHEN OTHERS THEN failed:=TRUE; END;
 IF NOT failed THEN RAISE EXCEPTION 'recovery event history was mutable'; END IF;
 IF has_function_privilege('authenticated','inspect_suspended_account_recovery(text)','EXECUTE')
  OR has_function_privilege('anon','file_suspended_account_recovery_appeal(text,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'client role can execute recovery RPC directly'; END IF;
END; $$;
ROLLBACK;
SELECT 'trust recovery negative-path E2E tests passed' AS result;