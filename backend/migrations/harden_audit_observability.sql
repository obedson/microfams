-- Harden shared audit evidence for tenant and correlation attribution.
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS resource_key TEXT;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS correlation_id UUID;
UPDATE audit_logs SET details = '{}'::JSONB WHERE details IS NULL;
ALTER TABLE audit_logs ALTER COLUMN details SET DEFAULT '{}'::JSONB,
  ALTER COLUMN details SET NOT NULL, ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_resource_key_length;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_resource_key_length CHECK (
  resource_key IS NULL OR length(resource_key) BETWEEN 1 AND 200
);
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_details_object;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_details_object
  CHECK (jsonb_typeof(details) = 'object');
CREATE INDEX IF NOT EXISTS idx_audit_logs_organization_created
  ON audit_logs(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_resource_key
  ON audit_logs(resource_type, resource_key) WHERE resource_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_correlation
  ON audit_logs(correlation_id) WHERE correlation_id IS NOT NULL;