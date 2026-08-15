BEGIN;
DO $$
<<fixture>>
DECLARE
 d TEXT; org UUID; owner UUID; deputy UUID; gid UUID; owner_member UUID; deputy_member UUID;
 proposal UUID; decided group_proposals; document_id UUID; version_id UUID; correction_id UUID;
BEGIN
 IF to_regclass('public.group_documents') IS NULL OR to_regclass('public.group_document_versions') IS NULL OR to_regclass('public.group_document_events') IS NULL THEN RAISE EXCEPTION 'GT10A document tables missing'; END IF;
 SELECT pg_get_functiondef('approve_group_document_version(UUID,UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_DOCUMENT_APPROVAL_REQUIRED%' OR d NOT LIKE '%document_publication%' OR d NOT LIKE '%correction_of_version_id%' THEN RAISE EXCEPTION 'GT10A publication invariant missing'; END IF;
 SELECT pg_get_functiondef('protect_group_document_evidence()'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_DOCUMENT_APPROVED_VERSION_IMMUTABLE%' OR d NOT LIKE '%GROUP_DOCUMENT_EVIDENCE_IMMUTABLE%' THEN RAISE EXCEPTION 'GT10A immutability invariant missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='group_documents' AND policyname='tenant_read') THEN RAISE EXCEPTION 'GT10A tenant policy missing'; END IF;

 SELECT organization_id,user_id INTO org,owner FROM organization_memberships WHERE status='active' AND role='owner' ORDER BY created_at LIMIT 1;
 IF org IS NULL THEN RAISE EXCEPTION 'GT10A tenant fixture is unavailable'; END IF;
 INSERT INTO users(email,password,name,role) VALUES('gt10a-'||replace(gen_random_uuid()::TEXT,'-','')||'@example.test','test','GT10A Deputy','farmer') RETURNING id INTO deputy;
 INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at) VALUES(org,deputy,'member','active',ARRAY['groups.documents.manage'],NOW());
 INSERT INTO groups(name,category,creator_id,organization_id,max_members) VALUES('GT10A Group','cooperative',owner,org,10) RETURNING id INTO gid;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
 INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid) VALUES(org,gid,deputy,'member','active',TRUE,'paid',1000) RETURNING id INTO deputy_member;
 PERFORM adopt_initial_group_constitution(org,gid,owner,'GT10A Constitution',jsonb_build_object('minimum_members',2,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false),'00000000-0000-4000-8000-000000001001','2026-08-15T09:00:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000001002','2026-08-15T09:01:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000001003','2026-08-15T09:02:00Z');
 PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000001004','2026-08-15T09:03:00Z');
 PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000001005','2026-08-15T09:04:00Z');

 BEGIN
  PERFORM create_group_document(org,gid,owner,'annual_minutes','minutes',owner,'{"visibility":"private"}','governance_7y','wrong-tenant/document.pdf',repeat('a',64),'application/pdf',128,'gt10a-invalid-path','00000000-0000-4000-8000-000000001006','2026-08-15T09:05:00Z');
  RAISE EXCEPTION 'a non-tenant document path was accepted';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='a non-tenant document path was accepted' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_DOCUMENT_COMMAND_INVALID%' THEN RAISE; END IF;
 END;

 document_id:=create_group_document(org,gid,owner,'annual_minutes','minutes',owner,'{"visibility":"private"}','governance_7y',org::TEXT||'/'||gid::TEXT||'/documents/annual-minutes-v1.pdf',repeat('a',64),'application/pdf',128,'gt10a-document-v1','00000000-0000-4000-8000-000000001007','2026-08-15T09:06:00Z');
 SELECT id INTO version_id FROM group_document_versions WHERE group_document_versions.document_id=fixture.document_id AND version=1;
 proposal:=create_group_proposal(org,gid,owner,'document_publication','Approve publication of the annual meeting minutes document.','[]',jsonb_build_object('document_key','annual_minutes'),ARRAY[]::UUID[],'2026-08-15T10:00:00Z','2026-08-15T11:00:00Z','00000000-0000-4000-8000-000000001008','2026-08-15T09:07:00Z');
 PERFORM open_group_proposal(org,gid,owner,proposal,1,'00000000-0000-4000-8000-000000001009','2026-08-15T10:00:00Z');
 PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve','00000000-0000-4000-8000-000000001010','2026-08-15T10:05:00Z');
 PERFORM cast_group_proposal_vote(org,gid,deputy,proposal,'approve','00000000-0000-4000-8000-000000001011','2026-08-15T10:06:00Z');
 SELECT * INTO decided FROM close_group_proposal(org,gid,owner,proposal,2,'00000000-0000-4000-8000-000000001012','2026-08-15T11:00:00Z');
 IF decided.state<>'approved' THEN RAISE EXCEPTION 'GT10A publication proposal was not approved'; END IF;
 PERFORM approve_group_document_version(org,gid,deputy,document_id,version_id,proposal,'00000000-0000-4000-8000-000000001013','2026-08-15T11:01:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_document_versions WHERE id=version_id AND state='approved' AND approved_by=deputy AND proposal_id=proposal) OR NOT EXISTS(SELECT 1 FROM group_documents WHERE id=document_id AND current_version_id=version_id) THEN RAISE EXCEPTION 'GT10A publication was not recorded'; END IF;

 BEGIN
  UPDATE group_document_versions SET storage_key=org::TEXT||'/'||gid::TEXT||'/documents/tampered.pdf' WHERE id=version_id;
  RAISE EXCEPTION 'an approved document version was mutated';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='an approved document version was mutated' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_DOCUMENT_APPROVED_VERSION_IMMUTABLE%' THEN RAISE; END IF;
 END;

 correction_id:=draft_group_document_correction(org,gid,owner,document_id,org::TEXT||'/'||gid::TEXT||'/documents/annual-minutes-v2.pdf',repeat('b',64),'application/pdf',144,'00000000-0000-4000-8000-000000001014','2026-08-15T11:02:00Z');
 IF NOT EXISTS(SELECT 1 FROM group_document_versions WHERE id=correction_id AND version=2 AND state='draft' AND correction_of_version_id=version_id) THEN RAISE EXCEPTION 'GT10A correction was not linked to the approved version'; END IF;
 BEGIN
  UPDATE group_document_events SET evidence='{"tampered":true}' WHERE group_document_events.document_id=fixture.document_id;
  RAISE EXCEPTION 'group document evidence was mutated';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='group document evidence was mutated' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE '%GROUP_DOCUMENT_EVIDENCE_IMMUTABLE%' THEN RAISE; END IF;
 END;
END $$;
SELECT 'group document versioning schema tests passed' AS result;
ROLLBACK;
