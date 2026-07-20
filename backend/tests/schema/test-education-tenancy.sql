DO $$
DECLARE
  tenant_course_id UUID;
  global_course_id UUID;
BEGIN
  INSERT INTO courses(title, description, organization_id)
  VALUES ('Supplier tenant course', 'Education isolation fixture', '00000000-0000-4000-8000-000000000101')
  RETURNING id INTO tenant_course_id;

  INSERT INTO courses(title, description)
  VALUES ('Global education course', 'Available to every active tenant')
  RETURNING id INTO global_course_id;

  INSERT INTO user_progress(organization_id, user_id, course_id, progress, completed)
  VALUES ('00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000102', global_course_id, 25, FALSE);

  BEGIN
    INSERT INTO user_progress(organization_id, user_id, course_id, progress, completed)
    VALUES ('00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000102', tenant_course_id, 25, FALSE);
    RAISE EXCEPTION 'cross-tenant course progress was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-tenant course progress was accepted' THEN RAISE; END IF;
  END;
END $$;

GRANT SELECT ON courses, user_progress TO authenticated;
SET ROLE authenticated;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM courses WHERE title = 'Supplier tenant course') THEN
    RAISE EXCEPTION 'course owner cannot read tenant course';
  END IF;
  IF EXISTS (SELECT 1 FROM user_progress WHERE organization_id = '00000000-0000-4000-8000-000000000102') THEN
    RAISE EXCEPTION 'course owner leaked another organization progress';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', FALSE);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM courses WHERE title = 'Supplier tenant course') THEN
    RAISE EXCEPTION 'tenant course leaked to unrelated organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM courses WHERE title = 'Global education course')
     OR NOT EXISTS (SELECT 1 FROM user_progress WHERE organization_id = '00000000-0000-4000-8000-000000000102') THEN
    RAISE EXCEPTION 'global learning progress is unavailable in learner organization';
  END IF;
END $$;
RESET ROLE;
