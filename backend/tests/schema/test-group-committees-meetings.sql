BEGIN;

DO $$
DECLARE
  org UUID; owner UUID; deputy UUID; member_user UUID; foreign_org UUID;
  gid UUID; owner_member UUID; deputy_member UUID; plain_member UUID;
  committee UUID; membership UUID; meeting UUID; minutes UUID; addendum UUID;
  proposal UUID; decided group_proposals;
  held group_meetings;
BEGIN
  SELECT organization_id,user_id INTO org,owner
  FROM organization_memberships WHERE status='active' AND role='owner'
  ORDER BY created_at LIMIT 1;
  IF org IS NULL THEN RAISE EXCEPTION 'GT-09 tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('gt09-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT09 Deputy','farmer')
    RETURNING id INTO deputy;
  INSERT INTO users(email,password,name,role) VALUES
    ('gt09-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT09 Member','farmer')
    RETURNING id INTO member_user;
  -- The deputy carries an explicit governance permission so independent minute
  -- approval can be exercised without granting tenant ownership.
  INSERT INTO organization_memberships(organization_id,user_id,role,status,permissions,joined_at)
    VALUES(org,deputy,'member','active',ARRAY['groups.governance.manage'],NOW());
  INSERT INTO organization_memberships(organization_id,user_id,role,status,joined_at)
    VALUES(org,member_user,'member','active',NOW());

  INSERT INTO groups(name,category,creator_id,organization_id,max_members)
    VALUES('GT09 Group','cooperative',owner,org,10) RETURNING id INTO gid;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,deputy,'owner','active',TRUE,'paid',1000) RETURNING id INTO deputy_member;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,member_user,'member','active',TRUE,'paid',1000) RETURNING id INTO plain_member;

  PERFORM adopt_initial_group_constitution(org,gid,owner,'GT09 Constitution',jsonb_build_object(
    'minimum_members',3,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,
    'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false
  ),'00000000-0000-4000-8000-000000000901','2026-08-06T09:00:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,
    '00000000-0000-4000-8000-000000000902','2026-08-06T09:01:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,
    '00000000-0000-4000-8000-000000000903','2026-08-06T09:02:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,
    '00000000-0000-4000-8000-000000000904','2026-08-06T09:03:00Z');
  PERFORM activate_group_with_constitution(org,gid,owner,1,
    '00000000-0000-4000-8000-000000000905','2026-08-06T09:04:00Z');

  -- A committee mandate is defined only by an approved, closed proposal.
  proposal:=create_group_proposal(org,gid,owner,'committee_mandate',
    'Establish a finance committee to review treasury activity and report back.','[]',
    jsonb_build_object('action','create','committee_key','finance',
      'display_name','Finance Committee',
      'mandate','Review treasury activity and report to the group.',
      'delegated_permissions',jsonb_build_array('groups.committee.recommend','groups.committee.report'),
      'spending_ceiling_minor_units','500000','spending_ceiling_currency','NGN',
      'reporting_duties','Quarterly report to the general meeting.',
      'term_ends_at','2027-08-06T09:00:00Z'),
    ARRAY[]::UUID[],'2026-08-06T10:00:00Z','2026-08-06T11:00:00Z',
    '00000000-0000-4000-8000-000000000906','2026-08-06T09:05:00Z');
  PERFORM open_group_proposal(org,gid,owner,proposal,1,
    '00000000-0000-4000-8000-000000000926','2026-08-06T10:00:00Z');
  PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve',
    '00000000-0000-4000-8000-000000000927','2026-08-06T10:05:00Z');
  PERFORM cast_group_proposal_vote(org,gid,deputy,proposal,'approve',
    '00000000-0000-4000-8000-000000000928','2026-08-06T10:06:00Z');
  SELECT * INTO decided FROM close_group_proposal(org,gid,owner,proposal,2,
    '00000000-0000-4000-8000-000000000929','2026-08-06T11:00:00Z');
  IF decided.state<>'approved' THEN RAISE EXCEPTION 'committee mandate proposal was not approved'; END IF;
  SELECT * INTO decided FROM execute_group_committee_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000930','2026-08-06T11:01:00Z');
  committee:=(decided.result->>'executed_resource_id')::UUID;
  IF decided.state<>'executed' OR NOT EXISTS(
    SELECT 1 FROM group_committees WHERE id=committee AND state='active'
      AND committee_key='finance' AND spending_ceiling_minor_units=500000
      AND spending_ceiling_currency='NGN' AND mandate_proposal_id=proposal
  ) THEN RAISE EXCEPTION 'approved committee mandate did not execute atomically'; END IF;
  IF (SELECT id FROM execute_group_committee_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000930','2026-08-06T11:01:00Z'))<>proposal
  THEN RAISE EXCEPTION 'committee mandate execution was not idempotent'; END IF;

  -- A committee cannot be created outside the proposal path.
  IF to_regprocedure('public.create_group_committee(uuid,uuid,uuid,text,text,text,text[],bigint,text,text,timestamp with time zone,uuid,timestamp with time zone)') IS NOT NULL
    OR to_regprocedure('public.dissolve_group_committee(uuid,uuid,uuid,uuid,text,uuid,timestamp with time zone)') IS NOT NULL
  THEN RAISE EXCEPTION 'a direct committee mandate command still exists'; END IF;

  -- A mandate carrying a non-delegable permission fails closed at execution.
  proposal:=create_group_proposal(org,gid,owner,'committee_mandate',
    'Establish a committee that attempts to hold group governance rights.','[]',
    jsonb_build_object('action','create','committee_key','seizure',
      'display_name','Seizure Committee','mandate','Attempt to hold a governance right.',
      'delegated_permissions',jsonb_build_array('groups.governance.manage')),
    ARRAY[]::UUID[],'2026-08-06T12:00:00Z','2026-08-06T13:00:00Z',
    '00000000-0000-4000-8000-000000000931','2026-08-06T11:05:00Z');
  PERFORM open_group_proposal(org,gid,owner,proposal,1,
    '00000000-0000-4000-8000-000000000932','2026-08-06T12:00:00Z');
  PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve',
    '00000000-0000-4000-8000-000000000933','2026-08-06T12:05:00Z');
  PERFORM cast_group_proposal_vote(org,gid,deputy,proposal,'approve',
    '00000000-0000-4000-8000-000000000934','2026-08-06T12:06:00Z');
  PERFORM close_group_proposal(org,gid,owner,proposal,2,
    '00000000-0000-4000-8000-000000000935','2026-08-06T13:00:00Z');
  BEGIN
    PERFORM execute_group_committee_proposal(org,gid,owner,proposal,3,
      '00000000-0000-4000-8000-000000000936','2026-08-06T13:01:00Z');
    RAISE EXCEPTION 'non-delegable committee permission was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='non-delegable committee permission was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE%' THEN RAISE; END IF;
  END;

  -- A committee has at most one sitting chair and no duplicate sitting member.
  membership:=add_group_committee_member(org,gid,owner,committee,owner_member,'chair',
    '00000000-0000-4000-8000-000000000908','2026-08-06T09:07:00Z');
  PERFORM add_group_committee_member(org,gid,owner,committee,plain_member,'member',
    '00000000-0000-4000-8000-000000000909','2026-08-06T09:08:00Z');
  BEGIN
    PERFORM add_group_committee_member(org,gid,owner,committee,deputy_member,'chair',
      '00000000-0000-4000-8000-000000000910','2026-08-06T09:09:00Z');
    RAISE EXCEPTION 'a second sitting chair was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='a second sitting chair was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_COMMITTEE_CHAIR_ALREADY_SERVING%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM add_group_committee_member(org,gid,owner,committee,plain_member,'member',
      '00000000-0000-4000-8000-000000000911','2026-08-06T09:10:00Z');
    RAISE EXCEPTION 'a duplicate sitting committee member was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='a duplicate sitting committee member was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_COMMITTEE_MEMBER_ALREADY_SERVING%' THEN RAISE; END IF;
  END;

  -- Only an emergency meeting may shorten the notice window.
  BEGIN
    PERFORM schedule_group_meeting(org,gid,owner,'general',NULL,'Rushed meeting',
      '[]'::JSONB,'2026-08-06T12:00:00Z',48,NULL,NULL,1,2,
      '00000000-0000-4000-8000-000000000912','2026-08-06T09:11:00Z');
    RAISE EXCEPTION 'a general meeting with short notice was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='a general meeting with short notice was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_MEETING_NOTICE_TOO_SHORT%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM schedule_group_meeting(org,gid,owner,'emergency',NULL,'Unexplained emergency',
      '[]'::JSONB,'2026-08-06T12:00:00Z',48,NULL,NULL,1,2,
      '00000000-0000-4000-8000-000000000913','2026-08-06T09:12:00Z');
    RAISE EXCEPTION 'an emergency meeting without a reason was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='an emergency meeting without a reason was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_MEETING_EMERGENCY_REASON_REQUIRED%' THEN RAISE; END IF;
  END;

  meeting:=schedule_group_meeting(org,gid,owner,'general',NULL,'Annual general meeting',
    jsonb_build_array(jsonb_build_object('sequence',1,'item','Treasury report')),
    '2026-08-10T10:00:00Z',48,NULL,'Community hall',1,2,
    '00000000-0000-4000-8000-000000000914','2026-08-06T09:13:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_meetings WHERE id=meeting AND state='scheduled'
    AND eligible_attendee_count=3 AND state_version=1)
  THEN RAISE EXCEPTION 'meeting scheduling did not snapshot eligible attendees'; END IF;

  -- Attendance is recorded once per member and never confers approval.
  PERFORM record_group_meeting_attendance(org,gid,owner,meeting,owner_member,'present',
    '00000000-0000-4000-8000-000000000915','2026-08-10T10:00:00Z');
  PERFORM record_group_meeting_attendance(org,gid,owner,meeting,deputy_member,'present',
    '00000000-0000-4000-8000-000000000916','2026-08-10T10:01:00Z');
  PERFORM record_group_meeting_attendance(org,gid,owner,meeting,plain_member,'apology',
    '00000000-0000-4000-8000-000000000917','2026-08-10T10:02:00Z');
  BEGIN
    PERFORM record_group_meeting_attendance(org,gid,owner,meeting,owner_member,'absent',
      '00000000-0000-4000-8000-000000000918','2026-08-10T10:03:00Z');
    RAISE EXCEPTION 'duplicate attendance was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='duplicate attendance was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_MEETING_ATTENDANCE_ALREADY_RECORDED%' THEN RAISE; END IF;
  END;

  -- Quorum is derived from the scheduling snapshot, not live membership.
  SELECT * INTO held FROM hold_group_meeting(org,gid,owner,meeting,1,
    '00000000-0000-4000-8000-000000000919','2026-08-10T10:30:00Z');
  IF held.state<>'held' OR held.quorum_met IS NOT TRUE OR held.state_version<>2
  THEN RAISE EXCEPTION 'holding the meeting did not evaluate quorum'; END IF;
  IF (SELECT id FROM hold_group_meeting(org,gid,owner,meeting,1,
    '00000000-0000-4000-8000-000000000919','2026-08-10T10:30:00Z'))<>meeting
  THEN RAISE EXCEPTION 'holding the meeting was not idempotent'; END IF;

  -- Draft minutes are correctable and approval is recorded against its actor.
  minutes:=draft_group_meeting_minutes(org,gid,owner,meeting,
    'The treasury report was received.',
    jsonb_build_array(jsonb_build_object('resolution','Receive the treasury report')),
    NULL,'00000000-0000-4000-8000-000000000920','2026-08-10T11:00:00Z');
  PERFORM approve_group_meeting_minutes(org,gid,deputy,minutes,
    '00000000-0000-4000-8000-000000000922','2026-08-10T11:02:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_meeting_minutes WHERE id=minutes AND state='approved'
    AND approved_by=deputy AND version=1)
  THEN RAISE EXCEPTION 'minute approval was not recorded against its approver'; END IF;

  -- Approved minutes are immutable, and corrections arrive as a linked addendum.
  BEGIN
    UPDATE group_meeting_minutes SET content='TAMPERED' WHERE id=minutes;
    RAISE EXCEPTION 'approved minutes were mutated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='approved minutes were mutated' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_COMMITTEE_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;
  addendum:=draft_group_meeting_minutes(org,gid,owner,meeting,
    'Correction: the treasury report covered the prior quarter.','[]'::JSONB,minutes,
    '00000000-0000-4000-8000-000000000923','2026-08-11T09:00:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_meeting_minutes WHERE id=addendum
    AND minutes_kind='addendum' AND corrects_minutes_id=minutes AND version=2)
  THEN RAISE EXCEPTION 'a correction did not create a linked addendum'; END IF;

  -- Dissolution is also proposal-executed and closes sitting memberships.
  proposal:=create_group_proposal(org,gid,owner,'committee_mandate',
    'Dissolve the finance committee now that its mandate is complete.','[]',
    jsonb_build_object('action','dissolve','committee_id',committee,
      'reason_code','MANDATE_COMPLETE'),
    ARRAY[]::UUID[],'2026-08-12T10:00:00Z','2026-08-12T11:00:00Z',
    '00000000-0000-4000-8000-000000000937','2026-08-12T09:00:00Z');
  PERFORM open_group_proposal(org,gid,owner,proposal,1,
    '00000000-0000-4000-8000-000000000938','2026-08-12T10:00:00Z');
  PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'approve',
    '00000000-0000-4000-8000-000000000939','2026-08-12T10:05:00Z');
  PERFORM cast_group_proposal_vote(org,gid,deputy,proposal,'approve',
    '00000000-0000-4000-8000-000000000940','2026-08-12T10:06:00Z');
  PERFORM close_group_proposal(org,gid,owner,proposal,2,
    '00000000-0000-4000-8000-000000000941','2026-08-12T11:00:00Z');
  PERFORM execute_group_committee_proposal(org,gid,owner,proposal,3,
    '00000000-0000-4000-8000-000000000942','2026-08-12T11:01:00Z');
  IF EXISTS(SELECT 1 FROM group_committee_members WHERE committee_id=committee AND ends_at IS NULL)
    OR NOT EXISTS(SELECT 1 FROM group_committees WHERE id=committee AND state='dissolved'
      AND dissolution_reason_code='MANDATE_COMPLETE')
  THEN RAISE EXCEPTION 'dissolution did not close the committee and its memberships'; END IF;

  -- Tenant isolation: a foreign organization cannot service this group.
  SELECT organization_id INTO foreign_org FROM organization_memberships
  WHERE organization_id<>org ORDER BY created_at LIMIT 1;
  IF foreign_org IS NOT NULL THEN
    BEGIN
      PERFORM add_group_committee_member(foreign_org,gid,owner,committee,plain_member,'member',
        '00000000-0000-4000-8000-000000000943','2026-08-12T11:02:00Z');
      RAISE EXCEPTION 'a foreign organization serviced a committee';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='a foreign organization serviced a committee' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE '%GROUP_GOVERNANCE_PERMISSION_DENIED%'
        AND SQLERRM NOT LIKE '%GROUP_NOT_FOUND%'
        AND SQLERRM NOT LIKE '%GROUP_COMMITTEE_NOT_ACTIVE%' THEN RAISE; END IF;
    END;
  END IF;
END $$;

ROLLBACK;

SELECT 'group committee and meeting schema tests passed' AS result;
