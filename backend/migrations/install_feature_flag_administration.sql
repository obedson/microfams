-- Trusted feature-flag administration with approved-only runtime evaluation.

ALTER TABLE feature_flags
  ADD COLUMN IF NOT EXISTS emergency_incident_reference TEXT;

ALTER TABLE feature_flag_overrides
  ADD COLUMN IF NOT EXISTS status TEXT,
  ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS decision_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS decision_reason TEXT;

UPDATE feature_flag_overrides
SET
  status = COALESCE(status, 'approved'),
  approved_at = COALESCE(approved_at, created_at),
  decided_by = COALESCE(decided_by, approved_by, created_by),
  decision_at = COALESCE(decision_at, created_at),
  decision_reason = COALESCE(decision_reason, reason)
WHERE status IS NULL
   OR approved_at IS NULL
   OR decided_by IS NULL
   OR decision_at IS NULL
   OR decision_reason IS NULL;

ALTER TABLE feature_flag_overrides
  ALTER COLUMN status SET DEFAULT 'pending',
  ALTER COLUMN status SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'feature_flag_override_status'
  ) THEN
    ALTER TABLE feature_flag_overrides
      ADD CONSTRAINT feature_flag_override_status
      CHECK (status IN ('pending', 'approved', 'rejected', 'revoked'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_feature_flag_approved_override_lookup
  ON feature_flag_overrides(feature_key, environment, scope_type, scope_id)
  WHERE status = 'approved';

CREATE OR REPLACE FUNCTION audit_feature_flag_change() RETURNS TRIGGER AS $$
DECLARE
  new_value JSONB := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
  old_value JSONB := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
  audit_actor UUID;
BEGIN
  audit_actor := COALESCE(
    CASE
      WHEN TG_OP = 'UPDATE'
       AND new_value->>'decided_by' IS DISTINCT FROM old_value->>'decided_by'
      THEN (new_value->>'decided_by')::UUID
    END,
    CASE
      WHEN TG_OP = 'UPDATE'
       AND new_value->>'emergency_changed_by' IS DISTINCT FROM old_value->>'emergency_changed_by'
      THEN (new_value->>'emergency_changed_by')::UUID
    END,
    (new_value->>'created_by')::UUID,
    (new_value->>'emergency_changed_by')::UUID,
    (old_value->>'created_by')::UUID,
    (old_value->>'emergency_changed_by')::UUID
  );

  INSERT INTO feature_flag_audit_log(feature_key, action, actor_id, before_value, after_value)
  VALUES (
    COALESCE(
      new_value->>'feature_key',
      new_value->>'key',
      old_value->>'feature_key',
      old_value->>'key'
    ),
    TG_OP,
    audit_actor,
    old_value,
    new_value
  );
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
