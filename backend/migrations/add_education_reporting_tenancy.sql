-- Tenant ownership for learning progress and tenant-authored education.

ALTER TABLE user_progress ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id);
ALTER TABLE user_progress ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

UPDATE user_progress progress
SET organization_id = CASE
  WHEN course.organization_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM organization_memberships membership
    WHERE membership.organization_id = course.organization_id
      AND membership.user_id = progress.user_id
      AND membership.status = 'active'
  ) THEN course.organization_id
  ELSE progress.user_id
END
FROM courses course
WHERE progress.course_id = course.id AND progress.organization_id IS NULL;

UPDATE user_progress SET organization_id = '00000000-0000-4000-8000-000000000900'
WHERE organization_id IS NULL;

ALTER TABLE user_progress ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE user_progress DROP CONSTRAINT IF EXISTS user_progress_user_id_course_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_progress_tenant_user_course
  ON user_progress(organization_id, user_id, course_id);
CREATE INDEX IF NOT EXISTS idx_user_progress_organization
  ON user_progress(organization_id, user_id, updated_at DESC);

CREATE OR REPLACE FUNCTION enforce_learning_progress_tenant() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_course_organization_id UUID;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM organization_memberships
    WHERE organization_id = NEW.organization_id
      AND user_id = NEW.user_id
      AND status = 'active'
  ) THEN RAISE EXCEPTION 'Learner is not an active organization member'; END IF;

  SELECT organization_id INTO v_course_organization_id FROM courses WHERE id = NEW.course_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course not found'; END IF;
  IF v_course_organization_id IS NOT NULL AND v_course_organization_id <> NEW.organization_id THEN
    RAISE EXCEPTION 'Course is not available to the selected organization';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_learning_progress_tenant ON user_progress;
CREATE TRIGGER enforce_learning_progress_tenant
BEFORE INSERT OR UPDATE OF organization_id, user_id, course_id ON user_progress
FOR EACH ROW EXECUTE FUNCTION enforce_learning_progress_tenant();

ALTER TABLE user_progress ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_read ON user_progress;
CREATE POLICY tenant_read ON user_progress FOR SELECT
  USING (has_active_organization_membership(organization_id));

REVOKE ALL ON user_progress FROM anon, authenticated;
GRANT ALL ON user_progress TO service_role;
