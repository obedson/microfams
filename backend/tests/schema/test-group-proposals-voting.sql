BEGIN;

DO $$
DECLARE
  org UUID; owner UUID; voter UUID; conflicted UUID; late_voter UUID;
  gid UUID; owner_member UUID; proposal UUID; special_proposal UUID; cancelled_proposal UUID;
  snapshot UUID; vote UUID; replay UUID; decided group_proposals; snap group_voting_snapshots;
BEGIN
  SELECT organization_id,user_id INTO org,owner
  FROM organization_memberships WHERE status='active' AND role='owner'
  ORDER BY created_at LIMIT 1;
  IF org IS NULL THEN RAISE EXCEPTION 'GT-03A tenant fixture is unavailable'; END IF;

  INSERT INTO users(email,password,name,role) VALUES
    ('gt03a-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT03A Voter','farmer') RETURNING id INTO voter;
  INSERT INTO users(email,password,name,role) VALUES
    ('gt03a-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT03A Conflicted','farmer') RETURNING id INTO conflicted;
  INSERT INTO users(email,password,name,role) VALUES
    ('gt03a-'||replace(gen_random_uuid()::text,'-','')||'@example.test','test','GT03A Late Voter','farmer') RETURNING id INTO late_voter;
  INSERT INTO organization_memberships(organization_id,user_id,role,status,joined_at)
    VALUES(org,voter,'member','active',NOW()),(org,conflicted,'member','active',NOW()),(org,late_voter,'member','active',NOW());

  INSERT INTO groups(name,category,creator_id,organization_id,max_members)
    VALUES('GT03A Group','cooperative',owner,org,10) RETURNING id INTO gid;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,owner,'owner','active',TRUE,'paid',1000) RETURNING id INTO owner_member;
  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,voter,'member','active',TRUE,'paid',1000),(org,gid,conflicted,'member','active',TRUE,'paid',1000);

  PERFORM adopt_initial_group_constitution(org,gid,owner,'GT03A Constitution',jsonb_build_object(
    'minimum_members',3,'ordinary_quorum_bps',5000,'ordinary_approval_bps',5001,
    'special_quorum_bps',6667,'special_approval_bps',6667,'vote_change_allowed',false
  ),'00000000-0000-4000-8000-000000000411','2026-08-02T09:00:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'chair',owner_member,NULL,'00000000-0000-4000-8000-000000000412','2026-08-02T09:01:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'secretary',owner_member,NULL,'00000000-0000-4000-8000-000000000413','2026-08-02T09:02:00Z');
  PERFORM appoint_initial_group_office(org,gid,owner,'treasurer',owner_member,NULL,'00000000-0000-4000-8000-000000000414','2026-08-02T09:03:00Z');
  PERFORM activate_group_with_constitution(org,gid,owner,1,'00000000-0000-4000-8000-000000000415','2026-08-02T09:04:00Z');

  proposal:=create_group_proposal(org,gid,owner,'constitution_amendment','Amend the constitution while excluding a directly conflicted member.','["evidence://case/1"]','{"action":"amend_constitution"}',ARRAY[conflicted],'2026-08-02T10:00:00Z','2026-08-02T11:00:00Z','00000000-0000-4000-8000-000000000416','2026-08-02T09:05:00Z');
  IF proposal<>create_group_proposal(org,gid,owner,'constitution_amendment','Amend the constitution while excluding a directly conflicted member.','["evidence://case/1"]','{"action":"amend_constitution"}',ARRAY[conflicted],'2026-08-02T10:00:00Z','2026-08-02T11:00:00Z','00000000-0000-4000-8000-000000000416','2026-08-02T09:05:00Z') THEN RAISE EXCEPTION 'proposal creation was not idempotent'; END IF;
  snapshot:=open_group_proposal(org,gid,owner,proposal,1,'00000000-0000-4000-8000-000000000417','2026-08-02T10:00:00Z');
  SELECT * INTO snap FROM group_voting_snapshots WHERE id=snapshot;
  IF snap.eligible_count<>2 OR snap.excluded_count<>1 OR snap.rule_kind<>'special'
    OR snap.quorum_count<>2 OR snap.approval_count<>2
  THEN RAISE EXCEPTION 'immutable special snapshot thresholds are wrong'; END IF;
  IF NOT EXISTS(SELECT 1 FROM group_voter_snapshot_members WHERE snapshot_id=snapshot AND user_id=conflicted AND NOT eligible AND exclusion_reason='DIRECT_CONFLICT') THEN RAISE EXCEPTION 'conflict exclusion was not evidenced'; END IF;

  BEGIN
    PERFORM cast_group_proposal_vote(org,gid,conflicted,proposal,'approve','00000000-0000-4000-8000-000000000418','2026-08-02T10:05:00Z');
    RAISE EXCEPTION 'conflicted voter was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='conflicted voter was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_VOTER_NOT_ELIGIBLE%' THEN RAISE; END IF;
  END;
  vote:=cast_group_proposal_vote(org,gid,owner,proposal,'approve','00000000-0000-4000-8000-000000000419','2026-08-02T10:06:00Z');
  replay:=cast_group_proposal_vote(org,gid,owner,proposal,'approve','00000000-0000-4000-8000-000000000419','2026-08-02T10:06:00Z');
  IF replay<>vote THEN RAISE EXCEPTION 'vote retry was not idempotent'; END IF;
  BEGIN
    PERFORM cast_group_proposal_vote(org,gid,owner,proposal,'reject','00000000-0000-4000-8000-000000000420','2026-08-02T10:07:00Z');
    RAISE EXCEPTION 'final vote was changed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='final vote was changed' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_VOTE_ALREADY_FINAL%' THEN RAISE; END IF;
  END;
  PERFORM cast_group_proposal_vote(org,gid,voter,proposal,'approve','00000000-0000-4000-8000-000000000421','2026-08-02T10:08:00Z');

  INSERT INTO group_members(organization_id,group_id,user_id,role,status,is_active,payment_status,amount_paid)
    VALUES(org,gid,late_voter,'member','active',TRUE,'paid',1000);
  IF (SELECT eligible_count FROM group_voting_snapshots WHERE id=snapshot)<>2 THEN RAISE EXCEPTION 'late membership altered voter snapshot'; END IF;

  SELECT * INTO decided FROM close_group_proposal(org,gid,owner,proposal,2,'00000000-0000-4000-8000-000000000422','2026-08-02T11:00:00Z');
  IF decided.state<>'approved' OR (decided.result->>'approvals')::INTEGER<>2
    OR NOT EXISTS(SELECT 1 FROM group_proposal_events WHERE proposal_id=proposal AND event_type='PROPOSAL_DECIDED' AND to_state='approved')
  THEN RAISE EXCEPTION 'proposal decision evidence is incomplete'; END IF;

  special_proposal:=create_group_proposal(org,gid,owner,'group_closure','Close the group after liabilities and member claims are settled.','[]','{}','{}','2026-08-02T12:00:00Z','2026-08-02T13:00:00Z','00000000-0000-4000-8000-000000000423','2026-08-02T11:30:00Z');
  snapshot:=open_group_proposal(org,gid,owner,special_proposal,1,'00000000-0000-4000-8000-000000000424','2026-08-02T12:00:00Z');
  SELECT * INTO snap FROM group_voting_snapshots WHERE id=snapshot;
  IF snap.rule_kind<>'special' OR snap.eligible_count<>4 OR snap.quorum_count<>3 OR snap.approval_count<>3 THEN RAISE EXCEPTION 'special integer-ceiling thresholds are wrong'; END IF;

  cancelled_proposal:=create_group_proposal(org,gid,owner,'ordinary','Cancel this draft before any voting snapshot is created.','[]','{}','{}','2026-08-02T14:00:00Z','2026-08-02T15:00:00Z','00000000-0000-4000-8000-000000000425','2026-08-02T13:30:00Z');
  SELECT * INTO decided FROM cancel_group_proposal(org,gid,owner,cancelled_proposal,1,'PROPOSER_WITHDREW','00000000-0000-4000-8000-000000000426','2026-08-02T13:31:00Z');
  IF decided.state<>'cancelled' OR decided.state_version<>2 OR NOT EXISTS(SELECT 1 FROM group_proposal_events WHERE proposal_id=cancelled_proposal AND event_type='PROPOSAL_CANCELLED' AND from_state='draft') THEN RAISE EXCEPTION 'proposal cancellation evidence is incomplete'; END IF;

  BEGIN
    UPDATE group_voting_snapshots SET eligible_count=999 WHERE id=snapshot;
    RAISE EXCEPTION 'voting snapshot was mutated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='voting snapshot was mutated' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_PROPOSAL_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM open_group_proposal(gen_random_uuid(),gid,owner,special_proposal,2,gen_random_uuid(),'2026-08-02T12:01:00Z');
    RAISE EXCEPTION 'cross-tenant proposal access succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='cross-tenant proposal access succeeded' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_%' THEN RAISE; END IF;
  END;
END $$;

ROLLBACK;

SELECT 'group proposals and voting schema tests passed' AS result;
