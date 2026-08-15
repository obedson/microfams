BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('pause_group_project(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%PROJECT_PAUSED%' OR d NOT LIKE '%GROUP_PROJECT_PAUSE_INVALID%' THEN RAISE EXCEPTION 'GT08B2 pause invariant missing'; END IF;
 SELECT pg_get_functiondef('resume_group_project(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%PROJECT_RESUMED%' OR d NOT LIKE '%GROUP_PROJECT_RESUME_INVALID%' THEN RAISE EXCEPTION 'GT08B2 resume invariant missing'; END IF;
END $$;
SELECT 'group project pause and resume schema tests passed' AS result;
ROLLBACK;
