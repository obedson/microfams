BEGIN;

DO $$
DECLARE
  v_admin UUID := '10000000-0000-4000-8000-000000000001';
  v_reviewer UUID := '10000000-0000-4000-8000-000000000002';
  v_appeal_reviewer UUID := '10000000-0000-4000-8000-000000000003';
  v_member UUID := '10000000-0000-4000-8000-000000000004';
  v_tenant_admin UUID := '10000000-0000-4000-8000-000000000005';
  v_outsider UUID := '10000000-0000-4000-8000-000000000006';
  v_org UUID := '20000000-0000-4000-8000-000000000001';
  v_membership UUID;
  v_case UUID;
  v_appeal UUID;
  v_result JSONB;
  v_failed BOOLEAN;
BEGIN
  INSERT INTO users(id, email, password, name, role) VALUES
    (v_admin, 'trust-admin@example.test', 'hash', 'Trust Admin', 'farmer'),
    (v_reviewer, 'trust-reviewer@example.test', 'hash', 'Trust Reviewer', 'farmer'),
    (v_appeal_reviewer, 'trust-appeal@example.test', 'hash', 'Appeal Reviewer', 'farmer'),
    (v_member, 'trust-member@example.test', 'hash', 'Trust Member', 'farmer'),
    (v_tenant_admin, 'trust-tenant-admin@example.test', 'hash', 'Tenant Admin', 'farmer'),
    (v_outsider, 'trust-outsider@example.test', 'hash', 'Other Tenant Owner', 'farmer');
  INSERT INTO organizations(id, name, slug, type, created_by)
  VALUES (v_org, 'Trust Test Cooperative', 'trust-test-cooperative', 'cooperative', v_member);
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES (v_org, v_member, 'member', 'active', NOW()) RETURNING id INTO v_membership;
  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES (v_org, v_tenant_admin, 'admin', 'active', NOW());
  INSERT INTO platform_administrator_assignments(user_id, grant_reason_code) VALUES
    (v_admin, 'TEST_BOOTSTRAP'), (v_reviewer, 'TEST_BOOTSTRAP'), (v_appeal_reviewer, 'TEST_BOOTSTRAP');

  v_result := open_trust_review_case(v_admin, v_org, 'membership', v_membership,
    'POLICY_REVIEW', 'high', 'open-case-0001', repeat('a', 64));
  v_case := (v_result->>'caseId')::UUID;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case was not opened'; END IF;
  IF open_trust_review_case(v_admin, v_org, 'membership', v_membership,
    'POLICY_REVIEW', 'high', 'open-case-0001', repeat('a', 64))->>'caseId' <> v_case::TEXT
  THEN RAISE EXCEPTION 'open case is not idempotent'; END IF;

  PERFORM assign_trust_review_case(v_admin, v_case, v_reviewer, 'assign-case-0001', repeat('b', 64));
  PERFORM declare_trust_reviewer_conflict(v_reviewer, v_case, 'prior_involvement', 'Prior case involvement',
    'conflict-case-01', repeat('c', 64));
  v_failed := FALSE;
  BEGIN
    PERFORM assign_trust_review_case(v_admin, v_case, v_reviewer, 'assign-case-0002', repeat('d', 64));
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'conflicted reviewer was reassigned'; END IF;

  PERFORM assign_trust_review_case(v_admin, v_case, v_appeal_reviewer, 'assign-case-0003', repeat('e', 64));
  PERFORM decide_trust_review_case(v_appeal_reviewer, v_case, 'suspend_membership', 'POLICY_BREACH',
    'Evidence supports a temporary membership suspension.', 'decide-case-001', repeat('f', 64));
  v_failed := FALSE;
  BEGIN
    PERFORM suspend_trust_membership(v_outsider, v_membership, v_case, 'POLICY_BREACH',
      'suspend-other-1', repeat('0', 64));
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'cross-tenant actor suspended membership'; END IF;

  PERFORM suspend_trust_membership(v_tenant_admin, v_membership, v_case, 'POLICY_BREACH',
    'suspend-member1', repeat('1', 64));
  IF (SELECT status FROM organization_memberships WHERE id = v_membership) <> 'suspended'
  THEN RAISE EXCEPTION 'membership was not suspended'; END IF;

  v_result := file_trust_appeal(v_member, v_case, 'The decision omitted material evidence supplied earlier.',
    'appeal-file-0001', repeat('2', 64));
  v_appeal := (v_result->>'appealId')::UUID;
  v_failed := FALSE;
  BEGIN
    PERFORM decide_trust_appeal(v_appeal_reviewer, v_appeal, 'overturned', 'NEW_EVIDENCE',
      'New evidence changes the original review outcome.', 'appeal-decide-1', repeat('3', 64));
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'original reviewer decided appeal'; END IF;

  PERFORM decide_trust_appeal(v_reviewer, v_appeal, 'overturned', 'NEW_EVIDENCE',
    'New evidence changes the original review outcome.', 'appeal-decide-2', repeat('4', 64));
  PERFORM resume_trust_membership(v_tenant_admin, v_membership, 'APPEAL_OVERTURNED',
    'resume-member-1', repeat('5', 64));
  IF (SELECT status FROM organization_memberships WHERE id = v_membership) <> 'active'
  THEN RAISE EXCEPTION 'membership was not resumed'; END IF;

  INSERT INTO data_retention_policies(organization_id, data_class, retention_days, enabled, created_by)
  VALUES (v_org, 'trust.case_metadata', 365, TRUE, v_admin) RETURNING id INTO v_case;
  v_result := create_retention_dry_run(v_admin, v_org, v_case, 'retention-run-01', repeat('6', 64));
  IF v_result->>'mode' <> 'dry_run' THEN RAISE EXCEPTION 'retention run is not dry-run'; END IF;
  v_failed := FALSE;
  BEGIN
    INSERT INTO data_retention_run_items(run_id, organization_id, resource_type, resource_id, proposed_action, reason_code, executed)
    VALUES ((v_result->>'runId')::UUID, v_org, 'review_case', 'x', 'would_delete', 'RETENTION_EXPIRED', TRUE);
  EXCEPTION WHEN check_violation THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'retention item allowed destructive execution'; END IF;

  v_failed := FALSE;
  BEGIN UPDATE trust_review_decisions SET rationale = 'tampered evidence' WHERE case_id = (SELECT case_id FROM trust_appeals WHERE id = v_appeal);
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'review decision was mutable'; END IF;
END $$;

SET LOCAL ROLE authenticated;
DO $$
DECLARE v_failed BOOLEAN := FALSE;
BEGIN
  BEGIN PERFORM count(*) FROM trust_review_cases;
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'authenticated role can directly read trust cases'; END IF;
END $$;
RESET ROLE;

ROLLBACK;
