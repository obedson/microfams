BEGIN;

DO $$
DECLARE
  org UUID; owner UUID; deputy UUID; member_user UUID; foreign_org UUID;
  gid UUID; owner_member UUID; deputy_member UUID; plain_member UUID;
  committee UUID; membership UUID; meeting UUID; minutes UUID; addendum UUID;
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

  -- Committee creation, idempotency, and non-delegable permission refusal.
  committee:=create_group_committee(org,gid,owner,'finance','Finance Committee',
    'Review treasury activity and report to the group.',
    ARRAY['groups.committee.recommend','groups.committee.report'],
    500000,'NGN','Quarterly report to the general meeting.','2027-08-06T09:00:00Z',
    '00000000-0000-4000-8000-000000000906','2026-08-06T09:05:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_committees WHERE id=committee AND state='active'
    AND committee_key='finance' AND spending_ceiling_minor_units=500000
    AND spending_ceiling_currency='NGN' AND constitution_id IS NOT NULL)
  THEN RAISE EXCEPTION 'committee creation did not record its mandate'; END IF;
  IF committee<>create_group_committee(org,gid,owner,'finance','Finance Committee',
    'Review treasury activity and report to the group.',
    ARRAY['groups.committee.recommend','groups.committee.report'],
    500000,'NGN','Quarterly report to the general meeting.','2027-08-06T09:00:00Z',
    '00000000-0000-4000-8000-000000000906','2026-08-06T09:05:00Z')
  THEN RAISE EXCEPTION 'committee creation was not idempotent'; END IF;

  BEGIN
    PERFORM create_group_committee(org,gid,owner,'seizure','Seizure Committee',
      'Attempt to hold a governance right the group cannot delegate.',
      ARRAY['groups.governance.manage'],NULL,NULL,NULL,NULL,
      '00000000-0000-4000-8000-000000000907','2026-08-06T09:06:00Z');
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

  -- Draft minutes are correctable; approval requires an independent actor.
  minutes:=draft_group_meeting_minutes(org,gid,owner,meeting,
    'The treasury report was received.',
    jsonb_build_array(jsonb_build_object('resolution','Receive the treasury report')),
    NULL,'00000000-0000-4000-8000-000000000920','2026-08-10T11:00:00Z');
  BEGIN
    PERFORM approve_group_meeting_minutes(org,gid,owner,minutes,
      '00000000-0000-4000-8000-000000000921','2026-08-10T11:01:00Z');
    RAISE EXCEPTION 'the drafter approved their own minutes';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='the drafter approved their own minutes' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_MEETING_MINUTES_INDEPENDENT_APPROVAL_REQUIRED%' THEN RAISE; END IF;
  END;
  PERFORM approve_group_meeting_minutes(org,gid,deputy,minutes,
    '00000000-0000-4000-8000-000000000922','2026-08-10T11:02:00Z');
  IF NOT EXISTS(SELECT 1 FROM group_meeting_minutes WHERE id=minutes AND state='approved'
    AND approved_by=deputy AND version=1)
  THEN RAISE EXCEPTION 'independent minute approval was not recorded'; END IF;

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

  -- Dissolution ends sitting memberships and blocks a reused active key.
  PERFORM dissolve_group_committee(org,gid,owner,committee,'MANDATE_COMPLETE',
    '00000000-0000-4000-8000-000000000924','2026-08-12T09:00:00Z');
  IF EXISTS(SELECT 1 FROM group_committee_members WHERE committee_id=committee AND ends_at IS NULL)
    OR NOT EXISTS(SELECT 1 FROM group_committees WHERE id=committee AND state='dissolved'
      AND dissolution_reason_code='MANDATE_COMPLETE')
  THEN RAISE EXCEPTION 'dissolution did not close the committee and its memberships'; END IF;

  -- Tenant isolation: a foreign organization cannot service this group.
  SELECT organization_id INTO foreign_org FROM organization_memberships
  WHERE organization_id<>org ORDER BY created_at LIMIT 1;
  IF foreign_org IS NOT NULL THEN
    BEGIN
      PERFORM create_group_committee(foreign_org,gid,owner,'audit','Audit Committee',
        'Attempt cross-tenant committee creation.',ARRAY[]::TEXT[],NULL,NULL,NULL,NULL,
        '00000000-0000-4000-8000-000000000925','2026-08-12T09:01:00Z');
      RAISE EXCEPTION 'a foreign organization created a committee';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='a foreign organization created a committee' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE '%GROUP_GOVERNANCE_PERMISSION_DENIED%'
        AND SQLERRM NOT LIKE '%GROUP_NOT_FOUND%' THEN RAISE; END IF;
    END;
  END IF;
END $$;

ROLLBACK;

SELECT 'group committee and meeting schema tests passed' AS result;
