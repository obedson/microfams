BEGIN;

DO $$
DECLARE
  org UUID; owner UUID; candidate UUID; delegate_user UUID;
  gid UUID; owner_member UUID; candidate_member UUID; delegate_member UUID;
  proposal UUID; snapshot UUID; assignment UUID; delegation UUID; decided group_proposals;
  service_result JSONB;
BEGIN
  SELECT organization_id,user_id INTO org,owner
  FROM organization_memberships WHERE status='active' AND role='owner'
  ORDER BY created_at LIMIT 1;
  IF org IS NULL THEN RAISE EXCEPTION 'GT-02D tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('gt02d-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT02D Candidate','farmer')
    RETURNING id INTO candidate;
  INSERT INTO users(email,password,name,role) VALUES
    ('gt02d-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT02D Delegate','farmer')
    RETURNING id INTO delegate_user;
  INSERT INTO organization_memberships(organization_id,user_id,role,status,joined_at)
    VALUES(org,candidate,'member','active',NOW()),(org,delegate_user,'member','active',NOW());

  INSERT INTO groups(name,category,creator_id,organization_id,max_members)
    VALUES('GT02D Group','cooperative',owner,org,10) RETURNING id INTO gid;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,candidate,'member','active',TRUE,'paid',1000) RETURNING id INTO candidate_member;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,delegate_user,'member','active',TRUE,'paid',1000) RETURNING id INTO delegate_member;

  PERFORM adopt_initial_group_constitution(org,gid,owner,'GT02D Constitution',jsonb_build_object(
    'minimum_members',3,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,
    'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false
  ),'00000000-0000-4000-8000-000000000711','2026-08-03T09:00:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,
    '00000000-0000-4000-8000-000000000712','2026-08-03T09:01:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,
    '00000000-0000-4000-8000-000000000713','2026-08-03T09:02:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,
    '00000000-0000-4000-8000-000000000714','2026-08-03T09:03:00Z');
  PERFORM activate_group_with_constitution(org,gid,owner,1,
    '00000000-0000-4000-8000-000000000715','2026-08-03T09:04:00Z');

  proposal:=create_group_proposal(org,gid,owner,'office_appointment',
    'Appoint the elected candidate as group treasurer for the approved term.','[]',
    jsonb_build_object('office_key','treasurer','member_id',candidate_member,
      'term_ends_at','2027-08-03T09:00:00Z'),ARRAY[candidate],
    '2026-08-03T10:00:00Z','2026-08-03T11:00:00Z',
    '00000000-0000-4000-8000-000000000716','2026-08-03T09:05:00Z');
  snapshot:=open_group_proposal(org,gid,owner,proposal,1,
    '00000000-0000-4000-8000-000000000717','2026-08-03T10:00:00Z');
  PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve',
    '00000000-0000-4000-8000-000000000718','2026-08-03T10:05:00Z');
  PERFORM cast_group_proposal_vote(org,gid,delegate_user,proposal,'approve',
    '00000000-0000-4000-8000-000000000719','2026-08-03T10:06:00Z');
  SELECT * INTO decided FROM close_group_proposal(org,gid,owner,proposal,2,
    '00000000-0000-4000-8000-000000000720','2026-08-03T11:00:00Z');
  IF decided.state<>'approved' THEN RAISE EXCEPTION 'office appointment proposal was not approved'; END IF;
  SELECT * INTO decided FROM execute_group_office_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000721','2026-08-03T11:01:00Z');
  assignment:=(decided.result->>'executed_resource_id')::UUID;
  IF decided.state<>'executed' OR decided.state_version<>5 OR NOT EXISTS(
    SELECT 1 FROM group_office_assignments WHERE id=assignment AND office_key='treasurer'
      AND user_id=candidate AND state='active' AND appointment_basis='approved_proposal'
  ) THEN RAISE EXCEPTION 'approved office appointment did not execute atomically'; END IF;
  IF (SELECT id FROM execute_group_office_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000721','2026-08-03T11:01:00Z'))<>proposal
  THEN RAISE EXCEPTION 'office proposal execution was not idempotent'; END IF;

  delegation:=delegate_group_office(org,gid,candidate,'treasurer',assignment,
    delegate_member,'2026-08-20T11:02:00Z',
    '00000000-0000-4000-8000-000000000722','2026-08-03T11:02:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_office_assignments WHERE id=delegation
    AND state='delegated' AND user_id=delegate_user AND delegated_from_assignment_id=assignment)
  THEN RAISE EXCEPTION 'bounded office delegation was not recorded'; END IF;
  IF delegation<>delegate_group_office(org,gid,candidate,'treasurer',assignment,
    delegate_member,'2026-08-20T11:02:00Z',
    '00000000-0000-4000-8000-000000000722','2026-08-03T11:02:00Z')
  THEN RAISE EXCEPTION 'office delegation was not idempotent'; END IF;

  PERFORM end_group_office_delegation(org,gid,candidate,'treasurer',delegation,
    'HOLDER_RETURNED','00000000-0000-4000-8000-000000000723','2026-08-10T11:02:00Z');
  SELECT id INTO assignment FROM group_office_assignments
  WHERE group_id=gid AND office_key='treasurer' AND state='active' AND user_id=candidate;
  IF assignment IS NULL OR NOT EXISTS(SELECT 1 FROM group_office_assignments
    WHERE id=delegation AND state='ended' AND end_reason_code='HOLDER_RETURNED')
  THEN RAISE EXCEPTION 'delegation end did not restore valid source holder'; END IF;

  delegation:=delegate_group_office(org,gid,candidate,'treasurer',assignment,
    delegate_member,'2026-08-11T08:00:00Z',
    '00000000-0000-4000-8000-000000000730','2026-08-10T11:03:00Z');
  service_result:=service_expired_group_offices(org,gid,owner,
    '00000000-0000-4000-8000-000000000731','2026-08-11T09:00:00Z');
  SELECT id INTO assignment FROM group_office_assignments
  WHERE group_id=gid AND office_key='treasurer' AND state='active' AND user_id=candidate;
  IF assignment IS NULL OR (service_result->>'serviced_count')::INTEGER<>1
    OR (service_result->>'restored_count')::INTEGER<>1 OR NOT EXISTS(
      SELECT 1 FROM group_office_assignments WHERE id=delegation AND state='ended'
        AND end_reason_code='DELEGATION_EXPIRED'
    ) THEN RAISE EXCEPTION 'expired delegation did not restore its valid source holder'; END IF;
  IF service_result<>service_expired_group_offices(org,gid,owner,
    '00000000-0000-4000-8000-000000000731','2026-08-11T09:00:00Z')
  THEN RAISE EXCEPTION 'office expiry servicing was not idempotent'; END IF;

  proposal:=create_group_proposal(org,gid,owner,'office_removal',
    'Remove the current treasurer after the recorded independent decision.','[]',
    jsonb_build_object('assignment_id',assignment,'reason_code','DUTY_BREACH'),
    ARRAY[candidate],'2026-08-11T10:00:00Z','2026-08-11T11:00:00Z',
    '00000000-0000-4000-8000-000000000724','2026-08-11T09:00:00Z');
  PERFORM open_group_proposal(org,gid,owner,proposal,1,
    '00000000-0000-4000-8000-000000000725','2026-08-11T10:00:00Z');
  PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve',
    '00000000-0000-4000-8000-000000000726','2026-08-11T10:05:00Z');
  PERFORM cast_group_proposal_vote(org,gid,delegate_user,proposal,'approve',
    '00000000-0000-4000-8000-000000000727','2026-08-11T10:06:00Z');
  PERFORM close_group_proposal(org,gid,owner,proposal,2,
    '00000000-0000-4000-8000-000000000728','2026-08-11T11:00:00Z');
  PERFORM execute_group_office_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000729','2026-08-11T11:01:00Z');
  IF EXISTS(SELECT 1 FROM group_office_assignments WHERE group_id=gid
    AND office_key='treasurer' AND state IN('active','delegated')) OR NOT EXISTS(
      SELECT 1 FROM group_office_assignments WHERE id=assignment AND state='removed'
        AND end_reason_code='DUTY_BREACH'
    ) THEN RAISE EXCEPTION 'approved removal did not create an evidenced vacancy'; END IF;

  BEGIN
    UPDATE group_office_assignments SET end_reason_code='TAMPERED' WHERE id=assignment;
    RAISE EXCEPTION 'office history mutation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='office history mutation was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_GOVERNANCE_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;

ROLLBACK;

SELECT 'group office lifecycle schema tests passed' AS result;
