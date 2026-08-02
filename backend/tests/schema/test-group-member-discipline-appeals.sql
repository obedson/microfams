BEGIN;
DO $$
DECLARE
  organization UUID;
  owner UUID;
  voter_one UUID;
  voter_two UUID;
  target UUID;
  reviewer UUID;
  group_identifier UUID;
  owner_membership UUID;
  target_membership UUID;
  case_result JSONB;
  case_identifier UUID;
  proposal_identifier UUID;
  snapshot_identifier UUID;
  appeal_identifier UUID;
  disciplined group_members;
BEGIN
  SELECT organization_id, user_id INTO organization, owner
  FROM organization_memberships
  WHERE status = 'active' AND role = 'owner'
  ORDER BY created_at LIMIT 1;
  INSERT INTO users(email, password, name, role)
  VALUES ('gt02c-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test', 'test', 'Discipline Voter One', 'farmer')
  RETURNING id INTO voter_one;
  INSERT INTO users(email, password, name, role)
  VALUES ('gt02c-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test', 'test', 'Discipline Voter Two', 'farmer')
  RETURNING id INTO voter_two;
  INSERT INTO users(email, password, name, role)
  VALUES ('gt02c-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test', 'test', 'Discipline Target', 'farmer')
  RETURNING id INTO target;
  INSERT INTO users(email, password, name, role)
  VALUES ('gt02c-' || replace(gen_random_uuid()::TEXT, '-', '') || '@example.test', 'test', 'Independent Reviewer', 'admin')
  RETURNING id INTO reviewer;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES
    (organization, voter_one, 'member', 'active', NOW()),
    (organization, voter_two, 'member', 'active', NOW()),
    (organization, target, 'member', 'active', NOW()),
    (organization, reviewer, 'admin', 'active', NOW());
  INSERT INTO groups(name, category, creator_id, organization_id, max_members, member_count)
  VALUES ('GT02C Discipline Group', 'cooperative', owner, organization, 10, 4)
  RETURNING id INTO group_identifier;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active,
    payment_status, amount_paid
  ) VALUES (
    organization, group_identifier, owner, 'owner', 'active', TRUE, 'paid', 1000
  ) RETURNING id INTO owner_membership;
  INSERT INTO group_members(
    organization_id, group_id, user_id, role, status, is_active,
    payment_status, amount_paid
  ) VALUES
    (organization, group_identifier, voter_one, 'member', 'active', TRUE, 'paid', 1000),
    (organization, group_identifier, voter_two, 'member', 'active', TRUE, 'paid', 1000),
    (organization, group_identifier, target, 'member', 'active', TRUE, 'paid', 1000);
  SELECT id INTO target_membership FROM group_members
  WHERE group_id = group_identifier AND user_id = target;

  PERFORM adopt_initial_group_constitution(
    organization, group_identifier, owner, 'GT02C Constitution',
    jsonb_build_object(
      'minimum_members', 2,
      'ordinary_quorum_bps', 5000,
      'ordinary_approval_bps', 5001,
      'special_quorum_bps', 6667,
      'special_approval_bps', 6667,
      'vote_change_allowed', FALSE
    ),
    '00000000-0000-4000-8000-000000000601', '2026-08-03T08:00:00Z'
  );
  PERFORM appoint_initial_group_office(organization, group_identifier, owner, 'chair', owner_membership, NULL, '00000000-0000-4000-8000-000000000602', '2026-08-03T08:01:00Z');
  PERFORM appoint_initial_group_office(organization, group_identifier, owner, 'secretary', owner_membership, NULL, '00000000-0000-4000-8000-000000000603', '2026-08-03T08:02:00Z');
  PERFORM appoint_initial_group_office(organization, group_identifier, owner, 'treasurer', owner_membership, NULL, '00000000-0000-4000-8000-000000000604', '2026-08-03T08:03:00Z');
  PERFORM activate_group_with_constitution(organization, group_identifier, owner, 1, '00000000-0000-4000-8000-000000000605', '2026-08-03T08:04:00Z');

  BEGIN
    PERFORM create_group_proposal(
      organization, group_identifier, owner, 'membership_action',
      'A direct discipline proposal must not bypass notice and case evidence.',
      jsonb_build_array('evidence://discipline/bypass'),
      jsonb_build_object('action', 'suspend'), ARRAY[target],
      '2026-08-03T09:00:00Z', '2026-08-04T09:00:00Z',
      gen_random_uuid(), '2026-08-03T08:05:00Z'
    );
    RAISE EXCEPTION 'direct discipline proposal bypassed the case workflow';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'direct discipline proposal bypassed the case workflow' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_DISCIPLINE_CASE_REQUIRED%' THEN RAISE; END IF;
  END;

  case_result := create_group_member_discipline_case(
    organization, group_identifier, owner, target_membership, 'suspend',
    'MATERIAL_POLICY_BREACH',
    'The member received notice of a documented material policy breach and may respond before voting opens.',
    jsonb_build_array('evidence://discipline/notice-001'),
    '2026-08-04T09:00:00Z', '2026-08-05T09:00:00Z', 30,
    '00000000-0000-4000-8000-000000000606', '2026-08-03T09:00:00Z'
  );
  case_identifier := (case_result ->> 'case_id')::UUID;
  proposal_identifier := (case_result ->> 'proposal_id')::UUID;
  IF case_identifier IS NULL OR proposal_identifier IS NULL
    OR NOT (case_result ->> 'created')::BOOLEAN
  THEN RAISE EXCEPTION 'discipline notice and proposal were not created atomically'; END IF;
  IF create_group_member_discipline_case(
    organization, group_identifier, owner, target_membership, 'suspend',
    'MATERIAL_POLICY_BREACH',
    'The member received notice of a documented material policy breach and may respond before voting opens.',
    jsonb_build_array('evidence://discipline/notice-001'),
    '2026-08-04T09:00:00Z', '2026-08-05T09:00:00Z', 30,
    '00000000-0000-4000-8000-000000000606', '2026-08-03T09:00:00Z'
  ) ->> 'case_id' <> case_identifier::TEXT
  THEN RAISE EXCEPTION 'discipline notice idempotency failed'; END IF;

  BEGIN
    PERFORM open_group_proposal(
      organization, group_identifier, owner, proposal_identifier, 1,
      '00000000-0000-4000-8000-000000000607', '2026-08-03T12:00:00Z'
    );
    RAISE EXCEPTION 'discipline vote opened before the response deadline';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'discipline vote opened before the response deadline' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_DISCIPLINE_RESPONSE_WINDOW_OPEN%'
      AND SQLERRM NOT LIKE '%GROUP_PROPOSAL_WINDOW_INVALID%'
    THEN RAISE; END IF;
  END;

  snapshot_identifier := open_group_proposal(
    organization, group_identifier, owner, proposal_identifier, 1,
    '00000000-0000-4000-8000-000000000608', '2026-08-04T09:00:00Z'
  );
  IF (SELECT rule_kind FROM group_voting_snapshots WHERE id = snapshot_identifier) <> 'discipline'
    OR EXISTS (
      SELECT 1 FROM group_voter_snapshot_members
      WHERE snapshot_id = snapshot_identifier AND user_id = target AND eligible
    )
  THEN RAISE EXCEPTION 'discipline conflict snapshot was not enforced'; END IF;
  PERFORM cast_group_proposal_vote(organization, group_identifier, owner, proposal_identifier, 'approve', '00000000-0000-4000-8000-000000000609', '2026-08-04T09:01:00Z');
  PERFORM cast_group_proposal_vote(organization, group_identifier, voter_one, proposal_identifier, 'approve', '00000000-0000-4000-8000-000000000610', '2026-08-04T09:02:00Z');
  PERFORM cast_group_proposal_vote(organization, group_identifier, voter_two, proposal_identifier, 'approve', '00000000-0000-4000-8000-000000000611', '2026-08-04T09:03:00Z');
  PERFORM close_group_proposal(organization, group_identifier, owner, proposal_identifier, 2, '00000000-0000-4000-8000-000000000612', '2026-08-05T09:00:00Z');

  disciplined := execute_group_member_discipline(
    organization, group_identifier, owner, case_identifier, 1,
    '00000000-0000-4000-8000-000000000613', '2026-08-05T09:01:00Z'
  );
  IF disciplined.status <> 'suspended' OR disciplined.is_active
    OR (SELECT member_count FROM groups WHERE id = group_identifier) <> 3
    OR (SELECT state FROM group_member_discipline_cases WHERE id = case_identifier) <> 'decided'
  THEN RAISE EXCEPTION 'approved suspension did not execute conservatively'; END IF;
  BEGIN
    UPDATE group_members SET status = 'active' WHERE id = target_membership;
    RAISE EXCEPTION 'discipline status was directly mutated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'discipline status was directly mutated' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_MEMBERSHIP_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;

  appeal_identifier := file_group_member_discipline_appeal(
    organization, group_identifier, target, case_identifier,
    'The decision omitted material evidence and should be reviewed independently.',
    jsonb_build_array('evidence://discipline/appeal-001'),
    '00000000-0000-4000-8000-000000000614', '2026-08-06T09:00:00Z'
  );
  BEGIN
    PERFORM decide_group_member_discipline_appeal(
      organization, group_identifier, owner, appeal_identifier, 'reinstate',
      'APPEAL_EVIDENCE_ACCEPTED', jsonb_build_array('evidence://discipline/review-001'),
      '00000000-0000-4000-8000-000000000615', '2026-08-06T10:00:00Z'
    );
    RAISE EXCEPTION 'original approving actor decided the appeal';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'original approving actor decided the appeal' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_DISCIPLINE_APPEAL_REVIEWER_CONFLICT%' THEN RAISE; END IF;
  END;
  disciplined := decide_group_member_discipline_appeal(
    organization, group_identifier, reviewer, appeal_identifier, 'reinstate',
    'APPEAL_EVIDENCE_ACCEPTED', jsonb_build_array('evidence://discipline/review-002'),
    '00000000-0000-4000-8000-000000000616', '2026-08-06T10:01:00Z'
  );
  IF disciplined.status <> 'active' OR NOT disciplined.is_active
    OR disciplined.current_discipline_case_id IS NOT NULL
    OR (SELECT member_count FROM groups WHERE id = group_identifier) <> 4
    OR (SELECT state FROM group_member_discipline_appeals WHERE id = appeal_identifier) <> 'reinstated'
    OR (SELECT resolution_outcome FROM group_member_discipline_cases WHERE id = case_identifier) <> 'reinstated'
  THEN RAISE EXCEPTION 'independent appeal did not restore membership exactly once'; END IF;

  BEGIN
    PERFORM create_group_member_discipline_case(
      gen_random_uuid(), group_identifier, owner, target_membership, 'expel',
      'CROSS_TENANT_ATTEMPT',
      'A cross tenant actor must not create or infer a member discipline record.',
      jsonb_build_array('evidence://discipline/cross-tenant'),
      '2026-08-08T09:00:00Z', '2026-08-09T09:00:00Z', 30,
      gen_random_uuid(), '2026-08-07T09:00:00Z'
    );
    RAISE EXCEPTION 'cross tenant discipline case succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross tenant discipline case succeeded' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%GROUP_%' THEN RAISE; END IF;
  END;
END;
$$;
ROLLBACK;
SELECT 'group member discipline and appeals schema tests passed' AS result;
