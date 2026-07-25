BEGIN;
DO $$
DECLARE
 a UUID:='73000000-0000-4000-8000-000000000001'; o UUID:='73000000-0000-4000-8000-000000000002'; other UUID:='73000000-0000-4000-8000-000000000003';
 p UUID; run UUID; held_case UUID; delete_case UUID; recent_case UUID; other_case UUID; result JSONB; failed BOOLEAN;
BEGIN
 INSERT INTO users(id,email,password,name,role) VALUES(a,'retention-admin@test.local','hash','Admin','farmer');
 INSERT INTO platform_administrator_assignments(user_id,grant_reason_code) VALUES(a,'TEST_BOOTSTRAP');
 INSERT INTO organizations(id,name,slug,type,created_by) VALUES(o,'Retention Org','retention-org','cooperative',a),(other,'Other Retention Org','other-retention-org','cooperative',a);
 INSERT INTO data_retention_policies(organization_id,data_class,retention_days,disposition,enabled,created_by) VALUES(o,'trust.case_metadata',30,'delete',TRUE,a) RETURNING id INTO p;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,opened_by,opened_at,idempotency_key,request_hash) VALUES
  (o,'organization',o,'TEST_CASE',a,NOW()-INTERVAL '90 days','ret-case-001',repeat('1',64)) RETURNING id INTO held_case;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,opened_by,opened_at,idempotency_key,request_hash) VALUES
  (o,'organization',o,'TEST_CASE',a,NOW()-INTERVAL '60 days','ret-case-002',repeat('2',64)) RETURNING id INTO delete_case;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,opened_by,opened_at,idempotency_key,request_hash) VALUES
  (o,'organization',o,'TEST_CASE',a,NOW()-INTERVAL '2 days','ret-case-003',repeat('3',64)) RETURNING id INTO recent_case;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,opened_by,opened_at,idempotency_key,request_hash) VALUES
  (other,'organization',other,'TEST_CASE',a,NOW()-INTERVAL '90 days','ret-case-004',repeat('4',64)) RETURNING id INTO other_case;
 INSERT INTO data_legal_holds(organization_id,subject_type,subject_id,reason_code,placed_by) VALUES(o,'case',held_case::TEXT,'LITIGATION_NOTICE',a);
 INSERT INTO data_retention_runs(organization_id,policy_id,requested_by,idempotency_key,request_hash) VALUES(o,p,a,'retention-run-001',repeat('5',64)) RETURNING id INTO run;
 result:=select_retention_dry_run_items(a,run,'ret-select-001',repeat('6',64));
 IF result->>'status'<>'completed' OR result#>>'{summary,total}'<>'2' OR result#>>'{summary,held}'<>'1' OR result#>>'{summary,wouldDelete}'<>'1' THEN RAISE EXCEPTION 'unexpected retention summary: %',result; END IF;
 IF NOT EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND resource_id=held_case::TEXT AND proposed_action='held' AND legal_hold_id IS NOT NULL) THEN RAISE EXCEPTION 'case hold did not override disposition'; END IF;
 IF NOT EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND resource_id=delete_case::TEXT AND proposed_action='would_delete' AND policy_id=p AND data_class='trust.case_metadata') THEN RAISE EXCEPTION 'eligible case was not classified'; END IF;
 IF EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND resource_id IN(recent_case::TEXT,other_case::TEXT)) THEN RAISE EXCEPTION 'cutoff or tenant scope leaked'; END IF;
 IF select_retention_dry_run_items(a,run,'ret-select-001',repeat('6',64))->>'runId'<>run::TEXT THEN RAISE EXCEPTION 'selection not idempotent'; END IF;
 failed:=FALSE; BEGIN UPDATE data_retention_run_items SET reason_code='TAMPERED' WHERE run_id=run; EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'retention evidence mutable'; END IF;
 failed:=FALSE; BEGIN UPDATE data_retention_runs SET summary='{}' WHERE id=run; EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'terminal retention run mutable'; END IF;
 IF EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND executed) THEN RAISE EXCEPTION 'dry run executed source mutation'; END IF;
 IF has_function_privilege('authenticated','select_retention_dry_run_items(uuid,uuid,text,text)','EXECUTE') THEN RAISE EXCEPTION 'authenticated role can select retention items'; END IF;
END; $$;
DO $$
DECLARE
 a UUID:='73000000-0000-4000-8000-000000000001'; o UUID:='73000000-0000-4000-8000-000000000002'; p UUID; run UUID;
 c1 UUID; c2 UUID; d1 UUID; d2 UUID; appeal1 UUID; appeal2 UUID; result JSONB;
BEGIN
 INSERT INTO data_retention_policies(organization_id,data_class,retention_days,disposition,enabled,created_by,policy_version) VALUES(o,'trust.appeal_metadata',30,'anonymize',TRUE,a,1) RETURNING id INTO p;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,priority,status,opened_by,assigned_reviewer_id,opened_at,assigned_at,decided_at,idempotency_key,request_hash) VALUES
  (o,'organization',o,'TEST_APPEAL','normal','decided',a,a,NOW()-INTERVAL '100 days',NOW()-INTERVAL '99 days',NOW()-INTERVAL '98 days','ret-appeal-case1',repeat('7',64)) RETURNING id INTO c1;
 INSERT INTO trust_review_decisions(case_id,organization_id,reviewer_id,outcome,reason_code,rationale,decided_at) VALUES(c1,o,a,'warning','TEST_DECISION','Schema test decision rationale.',NOW()-INTERVAL '98 days') RETURNING id INTO d1;
 INSERT INTO trust_appeals(case_id,decision_id,organization_id,appellant_id,grounds,filed_at,idempotency_key,request_hash) VALUES(c1,d1,o,a,'Schema test appeal grounds.',NOW()-INTERVAL '90 days','ret-appeal-001',repeat('8',64)) RETURNING id INTO appeal1;
 INSERT INTO trust_review_cases(organization_id,subject_type,subject_id,reason_code,priority,status,opened_by,assigned_reviewer_id,opened_at,assigned_at,decided_at,idempotency_key,request_hash) VALUES
  (o,'organization',o,'TEST_APPEAL','normal','decided',a,a,NOW()-INTERVAL '100 days',NOW()-INTERVAL '99 days',NOW()-INTERVAL '98 days','ret-appeal-case2',repeat('9',64)) RETURNING id INTO c2;
 INSERT INTO trust_review_decisions(case_id,organization_id,reviewer_id,outcome,reason_code,rationale,decided_at) VALUES(c2,o,a,'warning','TEST_DECISION','Schema test decision rationale.',NOW()-INTERVAL '98 days') RETURNING id INTO d2;
 INSERT INTO trust_appeals(case_id,decision_id,organization_id,appellant_id,grounds,filed_at,idempotency_key,request_hash) VALUES(c2,d2,o,a,'Another schema test appeal.',NOW()-INTERVAL '80 days','ret-appeal-002',repeat('a',64)) RETURNING id INTO appeal2;
 INSERT INTO data_legal_holds(organization_id,subject_type,subject_id,reason_code,placed_by) VALUES(o,'case',c1::TEXT,'LITIGATION_NOTICE',a);
 result:=create_retention_dry_run(a,o,p,'ret-appeal-run1',repeat('b',64)); run:=(result->>'runId')::UUID;
 result:=select_retention_dry_run_items(a,run,'ret-appeal-select1',repeat('c',64));
 IF result#>>'{summary,total}'<>'2' OR result#>>'{summary,held}'<>'1' OR result#>>'{summary,wouldAnonymize}'<>'1' THEN RAISE EXCEPTION 'unexpected appeal summary: %',result; END IF;
 IF NOT EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND resource_id=appeal1::TEXT AND proposed_action='held') THEN RAISE EXCEPTION 'parent case hold did not protect appeal'; END IF;
 IF NOT EXISTS(SELECT 1 FROM data_retention_run_items WHERE run_id=run AND resource_id=appeal2::TEXT AND proposed_action='would_anonymize') THEN RAISE EXCEPTION 'appeal was not classified for anonymization preview'; END IF;
END; $$;
ROLLBACK;
SELECT 'retention item-selection schema tests passed' AS result;