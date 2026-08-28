\set ON_ERROR_STOP on
BEGIN;

INSERT INTO users (id, email, password, name, role)
VALUES
  ('00000000-0000-4000-8000-000000000201', 'flag-maker@example.test', 'not-a-real-password', 'Flag Maker', 'admin'),
  ('00000000-0000-4000-8000-000000000202', 'flag-checker@example.test', 'not-a-real-password', 'Flag Checker', 'admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO feature_flags(key, domain, description, default_enabled, failure_mode, risk)
VALUES ('test.feature.admin', 'test', 'Feature administration schema test.', FALSE, 'closed', 'regulated')
ON CONFLICT (key) DO NOTHING;

INSERT INTO feature_flag_overrides(
  id, feature_key, scope_type, scope_id, environment, enabled, config, reason, created_by
)
VALUES (
  '00000000-0000-4000-8000-000000000301',
  'test.feature.admin',
  'tenant',
  'tenant-1',
  'staging',
  TRUE,
  '{"provider":"sandbox"}'::jsonb,
  'Enable after sandbox verification',
  '00000000-0000-4000-8000-000000000201'
);

DO $$
BEGIN
  IF (SELECT status FROM feature_flag_overrides WHERE id = '00000000-0000-4000-8000-000000000301') <> 'pending' THEN
    RAISE EXCEPTION 'new overrides must default to pending';
  END IF;
END $$;

UPDATE feature_flag_overrides
SET
  status = 'approved',
  approved_by = '00000000-0000-4000-8000-000000000202',
  approved_at = NOW(),
  decided_by = '00000000-0000-4000-8000-000000000202',
  decision_at = NOW(),
  decision_reason = 'Independent provider approval'
WHERE id = '00000000-0000-4000-8000-000000000301';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM feature_flag_audit_log
    WHERE feature_key = 'test.feature.admin'
      AND action = 'UPDATE'
      AND actor_id = '00000000-0000-4000-8000-000000000202'
      AND after_value->>'status' = 'approved'
  ) THEN
    RAISE EXCEPTION 'approval audit must identify the checker';
  END IF;

  IF has_table_privilege('authenticated', 'feature_flag_overrides', 'SELECT')
     OR has_table_privilege('anon', 'feature_flag_overrides', 'SELECT') THEN
    RAISE EXCEPTION 'feature flag overrides must not be directly client-readable';
  END IF;
END $$;

ROLLBACK;
