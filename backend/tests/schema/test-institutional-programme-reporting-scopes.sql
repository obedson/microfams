BEGIN;

INSERT INTO users(id, email, password, name, role) VALUES
  ('00000000-0000-4000-8000-000000005201', 'programme-owner@example.test', 'not-a-real-password', 'Programme Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000005202', 'participant-owner@example.test', 'not-a-real-password', 'Participant Owner', 'farmer'),
  ('00000000-0000-4000-8000-000000005203', 'programme-outsider@example.test', 'not-a-real-password', 'Programme Outsider', 'farmer');

INSERT INTO organizations(id, name, slug, type, created_by) VALUES
  (
    '00000000-0000-4000-8000-000000005210',
    'Programme Organization', 'programme-organization', 'government_program',
    '00000000-0000-4000-8000-000000005201'
  ),
  (
    '00000000-0000-4000-8000-000000005211',
    'Participant Cooperative', 'participant-cooperative', 'cooperative',
    '00000000-0000-4000-8000-000000005202'
  );

INSERT INTO organization_memberships(
  id, organization_id, user_id, role, permissions, status, joined_at
) VALUES
  (
    '00000000-0000-4000-8000-000000005220',
    '00000000-0000-4000-8000-000000005210',
    '00000000-0000-4000-8000-000000005201',
    'owner', '{}', 'active', NOW()
  ),
  (
    '00000000-0000-4000-8000-000000005221',
    '00000000-0000-4000-8000-000000005211',
    '00000000-0000-4000-8000-000000005202',
    'owner', '{}', 'active', NOW()
  );

INSERT INTO institutional_programmes(
  id, organization_id, name, description, status
) VALUES (
  '00000000-0000-4000-8000-000000005230',
  '00000000-0000-4000-8000-000000005210',
  'Aggregate Yield Programme', 'Aggregate outcome monitoring', 'active'
);

DO $$
BEGIN
  IF has_table_privilege(
    'service_role', 'institutional_programme_reporting_scopes', 'INSERT'
  ) OR has_table_privilege(
    'service_role', 'institutional_programme_reporting_scopes', 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'service role can bypass reporting-scope commands';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'request_programme_reporting_scope(uuid,uuid,uuid,uuid,text,text[],text,text,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'decide_programme_reporting_scope(uuid,uuid,uuid,text,text,text,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'browser clients can execute reporting-scope commands';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT request_programme_reporting_scope(
  '00000000-0000-4000-8000-000000005210',
  '00000000-0000-4000-8000-000000005201',
  '00000000-0000-4000-8000-000000005230',
  '00000000-0000-4000-8000-000000005211',
  'Measure aggregate participant and yield outcomes',
  ARRAY['aggregate.yield_total', 'aggregate.participant_count', 'aggregate.yield_total'],
  'programme-disclosure-v1',
  repeat('a', 64),
  NOW() + INTERVAL '30 days',
  NOW()
);
RESET ROLE;

DO $$
DECLARE
  v_scope institutional_programme_reporting_scopes;
BEGIN
  SELECT * INTO v_scope
  FROM institutional_programme_reporting_scopes
  WHERE programme_id = '00000000-0000-4000-8000-000000005230';

  IF v_scope.status <> 'pending'
     OR v_scope.permitted_metrics <> ARRAY[
       'aggregate.participant_count', 'aggregate.yield_total'
     ]
     OR v_scope.request_evidence_hash <> repeat('a', 64)
  THEN
    RAISE EXCEPTION 'reporting scope request was not normalized';
  END IF;
  IF (
    SELECT count(*) FROM organization_audit_log
    WHERE resource_id = v_scope.id::TEXT
      AND action IN (
        'programme.reporting_scope.requested',
        'programme.reporting_scope.consent_requested'
      )
  ) <> 2 THEN
    RAISE EXCEPTION 'reporting scope request was not audited for both tenants';
  END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_scope_id UUID;
BEGIN
  SELECT id INTO v_scope_id
  FROM institutional_programme_reporting_scopes
  WHERE programme_id = '00000000-0000-4000-8000-000000005230';

  BEGIN
    PERFORM decide_programme_reporting_scope(
      '00000000-0000-4000-8000-000000005211',
      '00000000-0000-4000-8000-000000005201',
      v_scope_id, 'granted', 'Programme owner cannot consent',
      repeat('b', 64), NOW() + INTERVAL '1 minute', NOW()
    );
    RAISE EXCEPTION 'programme owner granted participant consent';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%PROGRAMME_REPORTING_SCOPE_PERMISSION_DENIED%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM request_programme_reporting_scope(
      '00000000-0000-4000-8000-000000005210',
      '00000000-0000-4000-8000-000000005201',
      '00000000-0000-4000-8000-000000005230',
      '00000000-0000-4000-8000-000000005211',
      'Attempt row-level field access',
      ARRAY['participant.email'],
      'programme-disclosure-v1', repeat('c', 64),
      NOW() + INTERVAL '30 days', NOW()
    );
    RAISE EXCEPTION 'row-level metric identifier was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%PROGRAMME_REPORTING_SCOPE_INVALID%' THEN
      RAISE;
    END IF;
  END;

  PERFORM decide_programme_reporting_scope(
    '00000000-0000-4000-8000-000000005211',
    '00000000-0000-4000-8000-000000005202',
    v_scope_id, 'granted', 'Approved for minimized aggregate monitoring',
    repeat('d', 64), NOW() + INTERVAL '1 minute', NOW()
  );
END $$;
RESET ROLE;

DO $$
DECLARE
  v_scope institutional_programme_reporting_scopes;
BEGIN
  SELECT * INTO v_scope
  FROM institutional_programme_reporting_scopes
  WHERE programme_id = '00000000-0000-4000-8000-000000005230';

  IF v_scope.status <> 'granted'
     OR v_scope.decided_by <> '00000000-0000-4000-8000-000000005202'
     OR v_scope.consent_evidence_hash <> repeat('d', 64)
  THEN
    RAISE EXCEPTION 'participant consent was not recorded';
  END IF;
  IF (
    SELECT count(*) FROM organization_audit_log
    WHERE resource_id = v_scope.id::TEXT
      AND action = 'programme.reporting_scope.granted'
  ) <> 2 THEN
    RAISE EXCEPTION 'consent decision was not audited for both tenants';
  END IF;
END $$;

SET LOCAL ROLE service_role;
SELECT revoke_programme_reporting_scope(
  '00000000-0000-4000-8000-000000005211',
  '00000000-0000-4000-8000-000000005202',
  (
    SELECT id FROM institutional_programme_reporting_scopes
    WHERE programme_id = '00000000-0000-4000-8000-000000005230'
  ),
  'Participant withdrew consent',
  NOW()
);
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM institutional_programme_reporting_scopes
    WHERE programme_id = '00000000-0000-4000-8000-000000005230'
      AND status = 'revoked'
      AND revoked_by = '00000000-0000-4000-8000-000000005202'
  ) THEN
    RAISE EXCEPTION 'reporting scope revocation was not recorded';
  END IF;
  IF (
    SELECT count(*) FROM organization_audit_log
    WHERE action = 'programme.reporting_scope.revoked'
      AND resource_id = (
        SELECT id::TEXT FROM institutional_programme_reporting_scopes
        WHERE programme_id = '00000000-0000-4000-8000-000000005230'
      )
  ) <> 2 THEN
    RAISE EXCEPTION 'scope revocation was not audited for both tenants';
  END IF;
END $$;

SELECT 'institutional programme reporting scope schema tests passed' AS result;
ROLLBACK;
